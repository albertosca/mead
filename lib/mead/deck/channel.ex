defmodule Mead.Deck.Channel do
  @moduledoc """
  The deck's view of one session: one process per session that owns the event sequence, the
  event log, the prompt queue and the turn that runs.

  A socket (`Mead.Deck.Socket`) is only a translator between frames and calls on this process, so
  a deck that reconnects, or a second device, finds the same state. Every sequenced event is
  written to the log before it is sent to anyone: a deck can only have seen what a later replay
  can repeat, and a log that cannot be written stops the channel instead of sending an event the
  server could not stand behind.

  ## Turns

  `prompt.send` is idempotent on `client_message_id`: a repeated id gets its original
  `prompt.accepted` again and starts nothing. A new prompt is accepted, queued behind at most
  `queue_limit` others (a prompt over the limit is dropped without any event), and the queue runs
  one turn at a time through `Mead.submit_turn/3` in a task under `Mead.TurnSupervisor`. When a
  turn ends, its text arrives as a `text.delta` (unless it was already streamed), and
  `metric.updated` reports the session's token totals from the ledger. A failed turn emits no
  event of its own.

  The channel monitors the session and stops with it. It is registered in `Mead.Registry` as
  `{:deck, session_id}`.
  """

  use GenServer

  require Logger

  alias Mead.Deck.Configuration
  alias Mead.Deck.EventLog
  alias Mead.Deck.Events
  alias Mead.Session
  alias Mead.Session.Store

  @protocol_version 1

  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)

    GenServer.start_link(__MODULE__, options,
      name: {:via, Registry, {Mead.Registry, {:deck, session_id}}}
    )
  end

  @doc """
  Attaches `socket` (a pid that will receive `{:deck_event, binary}` messages), sends it the
  snapshot, and replays every sequenced event after `last_sequence`. All inside one call, so no
  live event can reach the socket before its snapshot.
  """
  @spec resume(GenServer.server(), pid(), non_neg_integer()) :: :ok
  def resume(channel, socket, last_sequence),
    do: GenServer.call(channel, {:resume, socket, last_sequence})

  @doc "Hands a validated client message from `socket` to the channel; unattached sockets are ignored."
  @spec client_message(GenServer.server(), pid(), Events.client_message()) :: :ok
  def client_message(channel, socket, message),
    do: GenServer.cast(channel, {:client_message, socket, message})

  @doc "The current permission policy level."
  @spec policy_level(GenServer.server()) :: Configuration.policy_level()
  def policy_level(channel), do: GenServer.call(channel, :policy_level)

  @impl GenServer
  def init(options) do
    session_id = Keyword.fetch!(options, :session_id)

    with {:ok, configuration} <- fetch_configuration(options),
         {:ok, server} <- fetch_session_server(session_id),
         directory = Keyword.get_lazy(options, :storage_directory, &Store.directory/0),
         {:ok, log} <- open_log(directory, session_id) do
      {:ok,
       %{
         session_id: session_id,
         configuration: configuration,
         log: log,
         session_monitor: Process.monitor(server),
         sockets: %{},
         accepted: accepted_prompts(log),
         queue: :queue.new(),
         running: nil,
         policy_level: derive_policy_level(log, configuration.default_policy_level)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp fetch_configuration(options) do
    case Keyword.fetch(options, :configuration) do
      {:ok, %Configuration{} = configuration} ->
        {:ok, configuration}

      :error ->
        case Configuration.load(Application.get_env(:mead, :deck, [])) do
          {:ok, configuration} -> {:ok, configuration}
          _disabled_or_invalid -> {:error, :deck_disabled}
        end
    end
  end

  defp fetch_session_server(session_id) do
    case Session.whereis(session_id, :server) do
      nil -> {:error, :session_not_found}
      pid -> {:ok, pid}
    end
  end

  defp open_log(directory, session_id) do
    case EventLog.open(directory, session_id) do
      {:ok, log} -> {:ok, log}
      {:error, reason} -> {:error, {:event_log, reason}}
    end
  end

  defp accepted_prompts(log) do
    log
    |> EventLog.read_after(0)
    |> Enum.reduce(%{}, fn
      %{"type" => "prompt.accepted", "sequence" => sequence, "payload" => payload}, accepted ->
        Map.put(accepted, payload["client_message_id"], sequence)

      _other, accepted ->
        accepted
    end)
  end

  defp derive_policy_level(log, default) do
    log
    |> EventLog.read_after(0)
    |> Enum.reverse()
    |> Enum.find_value(default, fn
      %{"type" => "policy.updated", "payload" => %{"level" => name}} ->
        case Events.parse_policy_level(name) do
          {:ok, level} -> level
          :error -> nil
        end

      _other ->
        nil
    end)
  end

  @impl GenServer
  def handle_call({:resume, socket, last_sequence}, _from, state) do
    state = monitor_socket(state, socket)
    current = EventLog.last_sequence(state.log)

    send(socket, {:deck_event, Events.encode(snapshot(state, current))})

    if last_sequence <= current do
      for envelope <- EventLog.read_after(state.log, last_sequence) do
        send(socket, {:deck_event, Events.encode(envelope)})
      end
    end

    {:reply, :ok, state}
  end

  def handle_call(:policy_level, _from, state), do: {:reply, state.policy_level, state}

  @impl GenServer
  def handle_cast({:client_message, socket, message}, state) do
    if Map.has_key?(state.sockets, socket) do
      handle_client_message(message, socket, state)
    else
      {:noreply, state}
    end
  end

  defp handle_client_message(
         {:prompt_send, %{client_message_id: client_message_id, text: text}},
         socket,
         state
       ) do
    case Map.fetch(state.accepted, client_message_id) do
      {:ok, sequence} ->
        resend(state, socket, sequence)
        {:noreply, state}

      :error ->
        accept_prompt(state, client_message_id, text)
    end
  end

  defp handle_client_message(_message, _socket, state), do: {:noreply, state}

  defp accept_prompt(state, client_message_id, text) do
    if :queue.len(state.queue) >= state.configuration.queue_limit do
      Logger.warning("deck prompt dropped: the queue is full")
      {:noreply, state}
    else
      payload = %{"client_message_id" => client_message_id, "text" => text}

      with {:ok, state, %{"sequence" => sequence}} <- emit(state, "prompt.accepted", payload) do
        state = %{
          state
          | accepted: Map.put(state.accepted, client_message_id, sequence),
            queue: :queue.in({sequence, text}, state.queue)
        }

        continue(start_next_turn(state))
      else
        {:error, reason} -> stop_for_log_failure(reason, state)
      end
    end
  end

  defp resend(state, socket, sequence) do
    case state.log |> EventLog.read_after(sequence - 1) |> Enum.take(1) do
      [envelope] -> send(socket, {:deck_event, Events.encode(envelope)})
      [] -> :ok
    end
  end

  defp start_next_turn(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {sequence, text}}, queue} ->
        session_id = state.session_id

        task =
          Task.Supervisor.async_nolink(Mead.TurnSupervisor, fn ->
            Mead.submit_turn(session_id, text, route: :auto, tools: :effect)
          end)

        %{state | queue: queue, running: %{ref: task.ref, turn_id: "turn-#{sequence}"}}

      {:empty, _queue} ->
        state
    end
  end

  defp start_next_turn(state), do: state

  @impl GenServer
  def handle_info({reference, result}, %{running: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    finish_turn(state, result)
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{running: %{ref: reference}} = state
      ),
      do: finish_turn(state, {:error, :turn_crashed})

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{session_monitor: reference} = state
      ),
      do: {:stop, {:shutdown, :session_gone}, state}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | sockets: Map.delete(state.sockets, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp finish_turn(%{running: %{turn_id: turn_id}} = state, result) do
    events = text_events(turn_id, result) ++ metric_events(state.session_id)

    case emit_all(%{state | running: nil}, events) do
      {:ok, state} -> continue(start_next_turn(state))
      {:error, reason} -> stop_for_log_failure(reason, state)
    end
  end

  defp text_events(turn_id, {:ok, output}) when is_binary(output) and output != "" do
    if String.valid?(output),
      do: [{"text.delta", %{"turn_id" => turn_id, "text" => output}}],
      else: []
  end

  defp text_events(_turn_id, _result), do: []

  defp metric_events(session_id) do
    totals =
      case Mead.session_usage(session_id) do
        {:ok, totals} -> totals
        {:error, :not_found} -> %{input_tokens: 0, output_tokens: 0}
      end

    [
      {"metric.updated",
       %{
         "key" => "tokens_in",
         "label" => "Tokens in",
         "value" => totals.input_tokens,
         "unit" => "tokens"
       }},
      {"metric.updated",
       %{
         "key" => "tokens_out",
         "label" => "Tokens out",
         "value" => totals.output_tokens,
         "unit" => "tokens"
       }}
    ]
  end

  defp continue(state), do: {:noreply, state}

  # A `:shutdown` exit is not a crash to OTP, so the report that a crash would print, with the
  # last message and the state, and in them the text of a prompt, is never written.
  defp stop_for_log_failure(reason, state) do
    Logger.error("deck event log failed, the channel stops: #{inspect(reason)}")
    {:stop, {:shutdown, {:log_failed, reason}}, state}
  end

  defp monitor_socket(state, socket) do
    if Map.has_key?(state.sockets, socket) do
      state
    else
      %{state | sockets: Map.put(state.sockets, socket, Process.monitor(socket))}
    end
  end

  defp snapshot(state, current_sequence) do
    Events.envelope(
      nil,
      state.session_id,
      "session.snapshot",
      %{
        "protocol_version" => @protocol_version,
        "current_sequence" => current_sequence,
        "permission_policy_level" => Events.policy_level_name(state.policy_level)
      },
      DateTime.utc_now()
    )
  end

  defp emit_all(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn {type, payload}, {:ok, current} ->
      case emit(current, type, payload) do
        {:ok, next, _envelope} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Writes the event to the log first, then sends it to every attached socket.
  defp emit(state, type, payload) do
    sequence = EventLog.last_sequence(state.log) + 1
    envelope = Events.envelope(sequence, state.session_id, type, payload, DateTime.utc_now())

    case EventLog.append(state.log, envelope) do
      {:ok, log} ->
        encoded = Events.encode(envelope)
        for socket <- Map.keys(state.sockets), do: send(socket, {:deck_event, encoded})
        {:ok, %{state | log: log}, envelope}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
