defmodule Mead.Deck.Socket do
  @moduledoc """
  One WebSocket connection of the deck: a translator between frames and calls on the session's
  `Mead.Deck.Channel`, which holds all the state, so a deck that reconnects finds it intact.

  The first message must be `session.resume`; it attaches the socket to the channel, which answers
  with the snapshot and replays what the deck missed. A socket that has not resumed within
  `resume_deadline_ms` is closed (1008), and so is one whose first message is anything else. After
  that, valid messages go to the channel and the channel's events come back as text frames.

  A frame that is binary, too large, not JSON, not an object, of an unknown type or with an invalid
  payload is ignored and logged by reason only, never by content. More than 20 of them in a minute
  close the socket (1008). A heartbeat is sent every `heartbeat_ms` whatever the channel is doing,
  so a long blocked turn does not look like a dead connection. The heartbeat is followed by a
  WebSocket ping; any frame from the client, a pong included, counts as activity, and a socket
  with none for `idle_timeout_ms` is closed (1001), so a silent client cannot hold it forever.
  """

  @behaviour WebSock

  require Logger

  alias Mead.Deck.Channel
  alias Mead.Deck.Events

  @invalid_frame_limit 20
  @invalid_frame_window_ms 60_000

  @impl WebSock
  def init(%{channel: channel, session_id: session_id, configuration: configuration}) do
    Process.monitor(channel)
    Process.send_after(self(), :resume_deadline, configuration.resume_deadline_ms)

    {:ok,
     %{
       channel: channel,
       session_id: session_id,
       configuration: configuration,
       resumed: false,
       invalid_frames: [],
       last_activity: now()
     }}
  end

  @impl WebSock
  def handle_in({data, [opcode: :text]}, state) do
    state = touch(state)

    case Events.decode_client(data) do
      {:ok, message} -> handle_message(message, state)
      {:error, reason} -> invalid_frame(reason, state)
    end
  end

  def handle_in({_data, [opcode: :binary]}, state), do: invalid_frame(:binary, touch(state))

  @impl WebSock
  def handle_control({_payload, [opcode: _ping_or_pong]}, state), do: {:ok, touch(state)}

  @impl WebSock
  def handle_info({:deck_event, binary}, state), do: {:push, {:text, binary}, state}

  def handle_info(:heartbeat, state) do
    if now() - state.last_activity > state.configuration.idle_timeout_ms do
      {:stop, :normal, {1001, "idle"}, state}
    else
      schedule_heartbeat(state)
      {:push, [{:text, heartbeat(state)}, {:ping, ""}], state}
    end
  end

  def handle_info(:resume_deadline, %{resumed: false} = state),
    do: {:stop, :normal, {1008, "session.resume expected"}, state}

  def handle_info({:DOWN, _reference, :process, channel, reason}, %{channel: channel} = state),
    do: {:stop, :normal, {1011, close_reason(reason)}, state}

  def handle_info(_message, state), do: {:ok, state}

  defp handle_message(
         {:session_resume, %{last_sequence: last_sequence, device_id: device_id}},
         %{resumed: false} = state
       ) do
    Channel.resume(state.channel, self(), last_sequence, device_id)
    schedule_heartbeat(state)
    {:ok, %{state | resumed: true}}
  catch
    :exit, _reason -> {:stop, :normal, {1011, "session closed"}, state}
  end

  # A second resume on a live socket changes nothing: the channel already replays to it.
  defp handle_message({:session_resume, _payload}, state), do: {:ok, state}

  defp handle_message(_message, %{resumed: false} = state),
    do: {:stop, :normal, {1008, "session.resume expected"}, state}

  defp handle_message(message, state) do
    Channel.client_message(state.channel, self(), message)
    {:ok, state}
  end

  defp close_reason({:shutdown, {:log_failed, _reason}}), do: "event log failed"
  defp close_reason(_reason), do: "session closed"

  defp invalid_frame(reason, state) do
    Logger.warning("deck socket ignored a frame: #{reason}")

    now = System.monotonic_time(:millisecond)

    recent =
      Enum.filter([now | state.invalid_frames], fn received_at ->
        now - received_at < @invalid_frame_window_ms
      end)

    state = %{state | invalid_frames: recent}

    if length(recent) > @invalid_frame_limit do
      {:stop, :normal, {1008, "too many invalid frames"}, state}
    else
      {:ok, state}
    end
  end

  defp touch(state), do: %{state | last_activity: now()}
  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_heartbeat(%{configuration: configuration}),
    do: Process.send_after(self(), :heartbeat, configuration.heartbeat_ms)

  defp heartbeat(state) do
    nil
    |> Events.envelope(state.session_id, "heartbeat", %{}, DateTime.utc_now())
    |> Events.encode()
  end
end
