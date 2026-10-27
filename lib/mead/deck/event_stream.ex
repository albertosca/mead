defmodule Mead.Deck.EventStream do
  @moduledoc """
  The Server-Sent Events fallback of the deck, for a network where a WebSocket cannot pass.

  `GET /deck/events` is a stream: the process serving the request attaches itself to the
  session's channel exactly as `Mead.Deck.Socket` does, so it receives the same events and writes
  each one as `data: <json envelope>`, with `id: <sequence>` for a sequenced event. The first
  event is `event: connected` with a `connection_token`; a sequenced event is never sent before
  it. A heartbeat envelope (no id) is sent every `heartbeat_ms`, and `event: closed` ends a stream
  whose session stopped.

  `POST /deck/messages` carries the client's messages back, one JSON message per request (the
  body of a WebSocket text frame), authorised by the `connection_token` as a bearer token. The
  token is bound to one live stream and dies with it. The single-use ticket cannot play that role:
  it opens exactly one stream, and a browser's automatic reconnect would find it already spent.
  To resume, the client asks `POST /deck/ticket` for a new ticket and opens the stream again with
  `last_sequence` (or `Last-Event-ID`), which replays what it missed from the event log.

  A client that goes away is noticed by a failed write, at the latest one heartbeat later; SSE has
  no pong, so there is no idle timer. Nothing here logs a message, a token or a ticket.
  """

  import Plug.Conn

  alias Mead.Deck.Channel
  alias Mead.Deck.Events

  @doc """
  Serves the stream until the client leaves or the channel goes down. `stream` is
  `%{session_id:, channel:, configuration:, last_sequence:, device_id:}`.
  """
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, stream) do
    token = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    key = {:deck_connection, token}
    value = %{session_id: stream.session_id, channel: stream.channel}
    {:ok, _owner} = Registry.register(Mead.Registry, key, value)
    channel_reference = Process.monitor(stream.channel)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("connection", "close")
      |> send_chunked(200)

    state = Map.merge(stream, %{channel_reference: channel_reference, timer: nil})

    try do
      open(conn, token, state)
    after
      Registry.unregister(Mead.Registry, key)
      leave(state)
    end
  end

  defp open(conn, token, state) do
    connected = JSON.encode!(%{"connection_token" => token, "session_id" => state.session_id})

    with {:ok, conn} <- chunk(conn, ["event: connected\ndata: ", connected, "\n\n"]) do
      try do
        Channel.resume(state.channel, self(), state.last_sequence, state.device_id)
        loop(conn, schedule_heartbeat(state))
      catch
        :exit, _reason -> finish(conn, "session closed")
      end
    else
      {:error, _reason} -> conn
    end
  end

  defp loop(conn, state) do
    receive do
      {:deck_event, binary} ->
        continue(conn, chunk(conn, frame(binary)), state)

      :heartbeat ->
        continue(conn, chunk(conn, frame(heartbeat(state))), schedule_heartbeat(state))

      {:DOWN, reference, :process, _pid, _reason} when reference == state.channel_reference ->
        finish(conn, "session closed")

      # The connection process traps exits, so its supervisor's shutdown arrives as a message.
      {:EXIT, _parent, reason} when reason == :shutdown or elem(reason, 0) == :shutdown ->
        finish(conn, "server shutting down")

      _ignored ->
        loop(conn, state)
    end
  end

  # A failed write means the client is gone; the stream ends and the cleanup runs.
  defp continue(_conn, {:ok, conn}, state), do: loop(conn, state)
  defp continue(conn, {:error, _reason}, _state), do: conn

  defp finish(conn, reason) do
    case chunk(conn, ["event: closed\ndata: ", JSON.encode!(%{"reason" => reason}), "\n\n"]) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp schedule_heartbeat(state) do
    timer = Process.send_after(self(), :heartbeat, state.configuration.heartbeat_ms)
    %{state | timer: timer}
  end

  # After detach returns the channel sends nothing more, so what is left in the mailbox is the
  # whole of it and can be dropped: the process may serve another request.
  defp leave(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Process.demonitor(state.channel_reference, [:flush])

    try do
      Channel.detach(state.channel, self())
    catch
      :exit, _reason -> :ok
    end

    flush()
  end

  defp flush do
    receive do
      {:deck_event, _binary} -> flush()
      :heartbeat -> flush()
    after
      0 -> :ok
    end
  end

  defp frame(binary) do
    case sequence(binary) do
      nil -> ["data: ", binary, "\n\n"]
      sequence -> ["id: ", Integer.to_string(sequence), "\ndata: ", binary, "\n\n"]
    end
  end

  defp sequence(binary) do
    case JSON.decode(binary) do
      {:ok, %{"sequence" => sequence}} when is_integer(sequence) -> sequence
      _other -> nil
    end
  end

  defp heartbeat(state) do
    nil
    |> Events.envelope(state.session_id, "heartbeat", %{}, DateTime.utc_now())
    |> Events.encode()
  end

  @doc """
  Hands one client message to the stream whose connection token is the bearer token. The token is
  checked before the body is read: `:unauthorized` for a missing or unknown one. Otherwise the
  answer is `202` accepted, `400` with the reason for a message the protocol refuses, or `413` for
  a body over the frame limit.
  """
  @spec message(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | :unauthorized
  def message(conn) do
    with {:ok, token} <- bearer(conn),
         [{stream_pid, %{channel: channel}}] <-
           Registry.lookup(Mead.Registry, {:deck_connection, token}) do
      {:ok, deliver(conn, channel, stream_pid)}
    else
      _unknown -> :unauthorized
    end
  end

  defp bearer(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, token}
    else
      _missing -> :error
    end
  end

  defp deliver(conn, channel, stream_pid) do
    case read_body(conn, length: Events.maximum_frame_bytes() + 1) do
      {:ok, body, conn} -> deliver_body(conn, body, channel, stream_pid)
      {:more, _partial, conn} -> reject(conn, 413, "too_large")
      {:error, _reason} -> reject(conn, 400, "unreadable_body")
    end
  end

  defp deliver_body(conn, body, channel, stream_pid) do
    case Events.decode_client(body) do
      {:ok, {:session_resume, _payload}} ->
        reject(conn, 400, "resume_not_accepted")

      {:ok, message} ->
        Channel.client_message(channel, stream_pid, message)
        send_resp(conn, 202, "")

      {:error, :too_large} ->
        reject(conn, 413, "too_large")

      {:error, reason} ->
        reject(conn, 400, Atom.to_string(reason))
    end
  end

  defp reject(conn, status, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{"error" => reason}))
  end
end
