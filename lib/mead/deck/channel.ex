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

  ## Permissions

  Every turn the channel starts carries `Mead.Deck.Interaction`, so the router asks the channel
  before each tool call. The policy level decides: `allow_all` emits `permission.requested` and,
  at once, `permission.resolved` with `decided_by_policy`; `ask_for_risky` lets a `:read` call run
  silently; anything else emits `permission.requested`, pauses the turn clock
  (`Mead.Session.Server.pause_clock/1`) and waits for the first valid `permission.respond` or for
  the deadline, which resolves as `expired`. A later answer gets the existing `permission.resolved`
  sent again to the answering socket alone. A request left open by a channel that died is resolved
  as `expired` when the next channel starts, before it serves anyone. The details of a request come
  from the model's arguments and are never logged.

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
  @maximum_detail_characters 2_000
  @permission_options [
    %{"option_id" => "allow_once", "label" => "Allow once", "kind" => "allow_once"},
    %{"option_id" => "reject_once", "label" => "Reject", "kind" => "reject_once"}
  ]

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
         {:ok, log} <- open_log(directory, session_id),
         {:ok, state} <-
           expire_dangling(%{
             session_id: session_id,
             configuration: configuration,
             log: log,
             session_monitor: Process.monitor(server),
             sockets: %{},
             devices: %{},
             next_device: 1,
             accepted: accepted_prompts(log),
             queue: :queue.new(),
             running: nil,
             policy_level: derive_policy_level(log, configuration.default_policy_level),
             pending: %{},
             calls: %{},
             open_cards: %{},
             resolved: resolved_requests(log)
           }) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolved_requests(log) do
    log
    |> EventLog.read_after(0)
    |> Enum.reduce(%{}, fn
      %{"type" => type, "sequence" => sequence, "payload" => payload}, resolved
      when type in ["permission.resolved", "choice.resolved"] ->
        Map.put(resolved, payload["request_id"], sequence)

      _other, resolved ->
        resolved
    end)
  end

  # A request in the log with no resolution belongs to a channel that died while it waited; the
  # turn that asked is gone with it, so the honest outcome is that nobody answered in time.
  defp expire_dangling(state) do
    open =
      state.log
      |> EventLog.read_after(0)
      |> Enum.filter(&(&1["type"] in ["permission.requested", "choice.requested"]))
      |> Enum.reject(&Map.has_key?(state.resolved, &1["payload"]["request_id"]))

    Enum.reduce_while(open, {:ok, state}, fn envelope, {:ok, current} ->
      payload = envelope["payload"]

      outcome =
        case envelope["type"] do
          "permission.requested" ->
            emit_resolved(current, payload["request_id"], payload["action"], "expired", %{})

          "choice.requested" ->
            emit_choice_resolved(current, payload["request_id"], nil, %{})
        end

      case outcome do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:event_log, reason}}}
      end
    end)
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

  def handle_call({:tool_updated, turn_id, update}, _from, state) do
    payload = %{
      "tool_call_id" => update.tool_call_id,
      "turn_id" => turn_id,
      "title" => update.title,
      "status" => Atom.to_string(update.status),
      "current_step" => update.current_step,
      "progress" => update.progress,
      "cancellable" => update.cancellable
    }

    case emit(state, "tool_call.updated", payload) do
      {:ok, state, _envelope} -> {:reply, :ok, finish_call(state, update, turn_id)}
      {:error, reason} -> stop_for_log_failure(reason, state)
    end
  end

  def handle_call({:register_call, tool_call_id, pid}, _from, state),
    do: {:reply, :ok, %{state | calls: Map.put(state.calls, tool_call_id, pid)}}

  def handle_call({:permission_request, request}, from, state) do
    case {state.policy_level, request.class} do
      {:allow_all, _class} -> approve_by_policy(state, request)
      {:ask_for_risky, :read} -> {:reply, :allow, state}
      _ask -> ask_permission(state, from, request)
    end
  end

  # A fragment of the streamed answer. A late one (its turn is over) is dropped; text that is not
  # valid UTF-8 cannot travel in a JSON frame and is dropped too, as the final text is.
  def handle_call({:text_delta, turn_id, text}, _from, state) do
    case state.running do
      %{turn_id: ^turn_id} = running when is_binary(text) and text != "" ->
        if String.valid?(text) do
          case emit(state, "text.delta", %{"turn_id" => turn_id, "text" => text}) do
            {:ok, state, _envelope} ->
              {:reply, :ok, %{state | running: Map.put(running, :streamed, true)}}

            {:error, reason} ->
              stop_for_log_failure(reason, state)
          end
        else
          {:reply, :ok, state}
        end

      _late_or_empty ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:choice_request, choice}, from, state), do: ask_choice(state, from, choice)

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

  defp handle_client_message(
         {:permission_respond, %{request_id: request_id, option_id: option_id}},
         socket,
         state
       ) do
    cond do
      match?(%{kind: :permission}, Map.get(state.pending, request_id)) ->
        answer_pending(state, socket, request_id, option_id)

      Map.has_key?(state.resolved, request_id) ->
        resend(state, socket, Map.fetch!(state.resolved, request_id))
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  defp handle_client_message(
         {:choice_respond, %{request_id: request_id, option_id: option_id}},
         socket,
         state
       ) do
    cond do
      match?(%{kind: :choice}, Map.get(state.pending, request_id)) ->
        answer_choice(state, socket, request_id, option_id)

      Map.has_key?(state.resolved, request_id) ->
        resend(state, socket, Map.fetch!(state.resolved, request_id))
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  # The router reports the outcome of a killed call itself, so cancelling only has to kill.
  defp handle_client_message({:tool_call_cancel, %{tool_call_id: tool_call_id}}, _socket, state) do
    case Map.fetch(state.calls, tool_call_id) do
      {:ok, pid} -> Process.exit(pid, :kill)
      :error -> :ok
    end

    {:noreply, state}
  end

  defp handle_client_message({:policy_set, %{level: level}}, _socket, state) do
    case emit(state, "policy.updated", %{"level" => Events.policy_level_name(level)}) do
      {:ok, state, _envelope} -> {:noreply, %{state | policy_level: level}}
      {:error, reason} -> stop_for_log_failure(reason, state)
    end
  end

  defp handle_client_message(_message, _socket, state), do: {:noreply, state}

  # `open_cards` remembers every tool card that has not reached a final status, so a turn that ends
  # underneath a running call can close it.
  defp finish_call(state, %{status: status, tool_call_id: tool_call_id}, _turn_id)
       when status in [:completed, :failed] do
    %{
      state
      | calls: Map.delete(state.calls, tool_call_id),
        open_cards: Map.delete(state.open_cards, tool_call_id)
    }
  end

  defp finish_call(state, %{tool_call_id: tool_call_id, title: title}, turn_id),
    do: %{state | open_cards: Map.put(state.open_cards, tool_call_id, {turn_id, title})}

  defp approve_by_policy(state, request) do
    request_id = new_request_id()

    with {:ok, state, _envelope} <-
           emit(state, "permission.requested", requested_payload(state, request_id, request)),
         {:ok, state} <-
           emit_resolved(state, request_id, action(request), "allowed", %{
             "decided_by_policy" => "allow_all"
           }) do
      {:reply, :allow, state}
    else
      {:error, reason} -> stop_for_log_failure(reason, state)
    end
  end

  defp ask_permission(state, {requester, _tag} = from, request) do
    request_id = new_request_id()

    case emit(state, "permission.requested", requested_payload(state, request_id, request)) do
      {:ok, state, _envelope} ->
        Session.Server.pause_clock(state.session_id)

        entry = %{
          kind: :permission,
          from: from,
          action: action(request),
          monitor: Process.monitor(requester),
          timer:
            Process.send_after(
              self(),
              {:request_deadline, request_id},
              state.configuration.permission_timeout_ms
            )
        }

        {:noreply, %{state | pending: Map.put(state.pending, request_id, entry)}}

      {:error, reason} ->
        stop_for_log_failure(reason, state)
    end
  end

  defp ask_choice(state, {requester, _tag} = from, choice) do
    request_id = new_request_id()

    payload = %{
      "request_id" => request_id,
      "tool_call_id" => choice.tool_call_id,
      "prompt" => choice.prompt,
      "options" => Enum.map(choice.options, &%{"id" => &1.id, "label" => &1.label})
    }

    case emit(state, "choice.requested", payload) do
      {:ok, state, _envelope} ->
        Session.Server.pause_clock(state.session_id)

        entry = %{
          kind: :choice,
          from: from,
          option_ids: Enum.map(choice.options, & &1.id),
          monitor: Process.monitor(requester),
          timer:
            Process.send_after(
              self(),
              {:request_deadline, request_id},
              state.configuration.permission_timeout_ms
            )
        }

        {:noreply, %{state | pending: Map.put(state.pending, request_id, entry)}}

      {:error, reason} ->
        stop_for_log_failure(reason, state)
    end
  end

  defp answer_choice(state, socket, request_id, option_id) do
    if option_id in state.pending[request_id].option_ids,
      do: settle(state, request_id, option_id, {:ok, option_id}, device_of(state, socket)),
      else: {:noreply, state}
  end

  # A pending request whose time is up or whose asker died: nobody answered.
  defp expire(state, request_id) do
    case state.pending[request_id].kind do
      :permission -> settle(state, request_id, "expired", {:deny, :expired}, %{})
      :choice -> settle(state, request_id, nil, {:error, :expired}, %{})
    end
  end

  defp answer_pending(state, socket, request_id, option_id) do
    case option_id do
      "allow_once" ->
        settle(state, request_id, "allowed", :allow, device_of(state, socket))

      "reject_once" ->
        settle(state, request_id, "rejected", {:deny, :rejected}, device_of(state, socket))

      _not_offered ->
        {:noreply, state}
    end
  end

  defp device_of(state, socket), do: %{"decided_by_device" => Map.get(state.devices, socket)}

  # Resolves an open request: log first, then wake the turn that is waiting for the answer.
  defp settle(state, request_id, outcome, answer, extra) do
    {entry, pending} = Map.pop!(state.pending, request_id)
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.monitor, [:flush])
    state = %{state | pending: pending}

    resolution =
      case entry.kind do
        :permission -> emit_resolved(state, request_id, entry.action, outcome, extra)
        :choice -> emit_choice_resolved(state, request_id, outcome, extra)
      end

    case resolution do
      {:ok, state} ->
        Session.Server.resume_clock(state.session_id)
        GenServer.reply(entry.from, answer)
        {:noreply, state}

      {:error, reason} ->
        stop_for_log_failure(reason, state)
    end
  end

  defp emit_choice_resolved(state, request_id, option_id, extra) do
    payload =
      Map.merge(
        %{
          "request_id" => request_id,
          "option_id" => option_id,
          "decided_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        extra
      )

    case emit(state, "choice.resolved", payload) do
      {:ok, state, envelope} ->
        {:ok, %{state | resolved: Map.put(state.resolved, request_id, envelope["sequence"])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_resolved(state, request_id, action, outcome, extra) do
    payload =
      Map.merge(
        %{
          "request_id" => request_id,
          "action" => action,
          "outcome" => outcome,
          "decided_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        extra
      )

    case emit(state, "permission.resolved", payload) do
      {:ok, state, envelope} ->
        {:ok, %{state | resolved: Map.put(state.resolved, request_id, envelope["sequence"])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp requested_payload(state, request_id, request) do
    expires_at =
      DateTime.add(DateTime.utc_now(), state.configuration.permission_timeout_ms, :millisecond)

    %{
      "request_id" => request_id,
      "action" => action(request),
      "risk_level" => if(request.class == :effect, do: "high", else: "low"),
      "details" => details(request.arguments),
      "options" => @permission_options,
      "expires_at" => DateTime.to_iso8601(expires_at)
    }
  end

  defp action(request), do: "Run #{request.tool} on the #{request.server} server"

  defp details(arguments) when is_map(arguments) do
    arguments
    |> Enum.map(fn {key, value} -> {render(key), value} end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> key <> ": " <> truncate(render(value)) end)
  end

  defp details(arguments), do: ["arguments: " <> truncate(render(arguments))]

  defp render(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp render(value), do: inspect(value, printable_limit: @maximum_detail_characters)

  defp truncate(text), do: String.slice(text, 0, @maximum_detail_characters)

  defp new_request_id,
    do: "request-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

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
        turn_id = "turn-#{sequence}"
        interaction = {Mead.Deck.Interaction, %{channel: self(), turn_id: turn_id}}

        task =
          Task.Supervisor.async_nolink(Mead.TurnSupervisor, fn ->
            Mead.submit_turn(session_id, text,
              route: :auto,
              tools: :effect,
              interaction: interaction
            )
          end)

        %{state | queue: queue, running: %{ref: task.ref, turn_id: turn_id}}

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

  def handle_info({:request_deadline, request_id}, state) do
    if Map.has_key?(state.pending, request_id) do
      expire(state, request_id)
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Enum.find(state.pending, fn {_id, entry} -> entry.monitor == reference end) do
      {request_id, _entry} ->
        expire(state, request_id)

      nil ->
        {:noreply,
         %{
           state
           | sockets: Map.delete(state.sockets, pid),
             devices: Map.delete(state.devices, pid)
         }}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish_turn(%{running: %{turn_id: turn_id}} = state, result) do
    with {:ok, state} <- close_open_cards(state),
         events = text_events(state.running, turn_id, result) ++ failure_events(turn_id, result),
         events = events ++ metric_events(state.session_id),
         {:ok, state} <- emit_all(%{state | running: nil}, events) do
      continue(start_next_turn(state))
    else
      {:error, reason} -> stop_for_log_failure(reason, state)
    end
  end

  # A tool still running when its turn ends (timeout, crash) is killed and its card is closed as
  # failed, so no card stays "running" and no cancel waits for a confirmation that never comes.
  defp close_open_cards(state) do
    Enum.reduce_while(state.open_cards, {:ok, state}, fn {tool_call_id, {turn_id, title}},
                                                         {:ok, state} ->
      case Map.fetch(state.calls, tool_call_id) do
        {:ok, pid} -> Process.exit(pid, :kill)
        :error -> :ok
      end

      payload = %{
        "tool_call_id" => tool_call_id,
        "turn_id" => turn_id,
        "title" => title,
        "status" => "failed",
        "current_step" => "turn ended",
        "progress" => nil,
        "cancellable" => false
      }

      case emit(state, "tool_call.updated", payload) do
        {:ok, state, _envelope} ->
          {:cont,
           {:ok,
            %{
              state
              | calls: Map.delete(state.calls, tool_call_id),
                open_cards: Map.delete(state.open_cards, tool_call_id)
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp failure_events(turn_id, {:error, reason}),
    do: [{"turn.failed", %{"turn_id" => turn_id, "reason" => failure_reason(reason)}}]

  defp failure_events(_turn_id, _result), do: []

  # Only the name of an atom reason is sent; anything else could carry what the model or a tool said.
  defp failure_reason({:failed, reason}), do: failure_reason(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_reason), do: "failed"

  # A turn that streamed already sent its text piece by piece; the whole of it is not sent again.
  defp text_events(%{streamed: true}, _turn_id, _result), do: []

  defp text_events(_running, turn_id, {:ok, output}) when is_binary(output) and output != "" do
    if String.valid?(output),
      do: [{"text.delta", %{"turn_id" => turn_id, "text" => output}}],
      else: []
  end

  defp text_events(_running, _turn_id, _result), do: []

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
      %{
        state
        | sockets: Map.put(state.sockets, socket, Process.monitor(socket)),
          devices: Map.put(state.devices, socket, "device-#{state.next_device}"),
          next_device: state.next_device + 1
      }
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
