defmodule Mead.Session.Server do
  @moduledoc """
  Orchestrates the turns of one conversation.

  It records each turn in the history before running the handler, runs the handler in a task
  under `Mead.TurnSupervisor`, and replies to the caller once the task reports back. A handler
  that raises, exits, returns garbage, or runs past the turn timeout fails only that turn. A
  failed turn replies `{:error, {:failed, reason}}`, with the same reason stored as its output.

  The task is linked to the server and the server traps exits. A task failure therefore arrives
  as a message instead of killing the server, while a server death takes the running task down
  with it, so no orphaned handler keeps running for a conversation that restarted.

  A turn submitted with a `client_turn_id` runs at most once. The key is recorded on the turn, so
  it survives restarts and resumes. A submit that repeats the key and the input of the running
  turn joins its waiters and gets the same reply; one that repeats an ended turn gets the stored
  outcome at once, an interrupted one included, and nothing runs again; one that repeats the key
  with another input is a conflict. Waiters are monitored, and one that dies leaves the list
  while the turn keeps running.

  The turn clock can be suspended with `pause_clock/1` and `resume_clock/1`, for a turn that waits
  for a person: while at least one pause is open the turn cannot time out, and the last resume
  restarts the timer with the time that was left. Pauses nest by counting, and neither call does
  anything when no turn is running, so a pause can never leak into the next turn.

  Every turn gets a `:checkpoint` option that records its steps in the history. When the server
  starts and the newest turn is still in progress, it continues that turn when it can: the turn
  has a `client_turn_id`, the options it was submitted with were recorded, and the handler
  implements `resume_turn/4`. The continuation runs with no waiters (a submit repeating the key
  joins it) and gets the recorded steps. A turn is continued at most 3 times; the next start,
  and every turn that cannot continue, marks it interrupted. While a turn that can continue runs,
  the session has a marker under `Mead.Session.Pending`, so recovery after a node stop finds it.

  A reader that bypasses the server can observe an interrupted turn as in progress in the moment
  between the new server registering its name and finishing `init/1`.
  """

  use GenServer

  require Logger

  alias Mead.Session
  alias Mead.Session.History
  alias Mead.Session.Pending
  alias Mead.Session.Turn

  # How many times one turn may be continued before the next start interrupts it, so a turn that
  # crashes its server every time cannot loop.
  @maximum_resumes 3

  @doc """
  Starts the server for `options[:session_id]`, registered under `Mead.Registry`.

  Required options are `:session_id`, `:handler`, and `:turn_timeout`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    GenServer.start_link(__MODULE__, options, name: Session.via(session_id, :server))
  end

  @doc """
  Suspends the clock of the running turn; every call must be matched by one `resume_clock/1`.
  `:ok` when no turn is running, `{:error, :not_found}` for an unknown session.
  """
  @spec pause_clock(String.t()) :: :ok | {:error, :not_found}
  def pause_clock(session_id), do: clock_call(session_id, :pause_clock)

  @doc "Undoes one `pause_clock/1`; the timer restarts when the last pause is undone."
  @spec resume_clock(String.t()) :: :ok | {:error, :not_found}
  def resume_clock(session_id), do: clock_call(session_id, :resume_clock)

  defp clock_call(session_id, request) do
    case Session.whereis(session_id, :server) do
      nil -> {:error, :not_found}
      server -> GenServer.call(server, request, :infinity)
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(options, :session_id)

    state = %{
      session_id: session_id,
      handler: Keyword.fetch!(options, :handler),
      turn_timeout: Keyword.fetch!(options, :turn_timeout),
      directory: Keyword.get(options, :directory),
      running: nil
    }

    if continuable?(History.newest(session_id), state.handler) do
      {:ok, state, {:continue, :resume}}
    else
      {:ok, abandon_in_progress(state)}
    end
  end

  @impl true
  def handle_continue(:resume, state) do
    case History.begin_resume(state.session_id, @maximum_resumes) do
      {:ok, turn} ->
        earlier = state.session_id |> History.all() |> Enum.drop(-1)
        handler = state.handler

        options =
          turn.turn_options
          |> handler_options(state.session_id)
          |> Keyword.put(:checkpoint, checkpoint(state.session_id, turn.resumes))

        task =
          Task.Supervisor.async(Mead.TurnSupervisor, fn ->
            handler.resume_turn(earlier, turn.input, turn.steps, options)
          end)

        {:noreply, %{state | running: new_running(task, [], true, state.turn_timeout)}}

      {:error, reason} ->
        Logger.warning(
          "could not continue the turn of session #{state.session_id}: #{inspect(reason)}"
        )

        {:noreply, abandon_in_progress(state)}
    end
  end

  # Only a keyed turn that recorded its options can be continued, and only by a handler that
  # knows how.
  defp continuable?(
         %Turn{status: :in_progress, client_turn_id: key, turn_options: turn_options},
         handler
       )
       when is_binary(key) and turn_options != %{},
       do: resumable?(handler)

  defp continuable?(_newest, _handler), do: false

  defp resumable?(handler),
    do: Code.ensure_loaded?(handler) and function_exported?(handler, :resume_turn, 4)

  # The turn left in progress cannot continue: it ends interrupted (in memory even when the write
  # fails), and the marker it may have left goes with it.
  defp abandon_in_progress(state) do
    record(History.mark_interrupted(state.session_id), state.session_id)
    clear_marker(state)
    state
  end

  defp clear_marker(state) do
    case Pending.clear(state.directory, state.session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not remove the pending marker of session #{state.session_id}: #{inspect(reason)}"
        )
    end
  end

  # What the handler needs to continue the turn, kept on the turn. Never a pid or a context.
  defp turn_options(options) do
    %{
      route: Keyword.get(options, :route, :auto),
      tools: Keyword.get(options, :tools),
      interactive: Keyword.has_key?(options, :interaction)
    }
  end

  defp handler_options(%{route: route, tools: tools}, session_id) do
    [route: route]
    |> then(fn options -> if tools, do: Keyword.put(options, :tools, tools), else: options end)
    |> Keyword.put(:session_id, session_id)
  end

  defp checkpoint(session_id, attempt),
    do: fn step -> History.append_step(session_id, attempt, step) end

  @impl true
  def handle_call({:submit, input, options}, from, state) do
    {client_turn_id, options} = Keyword.pop(options, :client_turn_id)
    running = state.running

    case earlier_turn(state.session_id, client_turn_id) do
      nil ->
        start_turn(state, input, options, client_turn_id, from)

      %Turn{input: ^input, status: :in_progress} when running != nil ->
        {:noreply, %{state | running: %{running | waiters: [waiter(from) | running.waiters]}}}

      %Turn{input: ^input} = turn ->
        {:reply, reply_for({turn.status, turn.output}), state}

      %Turn{} = turn ->
        {:reply, {:error, {:client_turn_id_conflict, conflict_details(turn)}}, state}
    end
  end

  def handle_call(request, _from, %{running: nil} = state)
      when request in [:pause_clock, :resume_clock],
      do: {:reply, :ok, state}

  def handle_call(:pause_clock, _from, %{running: running} = state) do
    running =
      if running.pauses == 0 do
        Process.cancel_timer(running.timer)
        %{running | timer: nil, remaining: max(running.deadline - now(), 1)}
      else
        running
      end

    {:reply, :ok, %{state | running: %{running | pauses: running.pauses + 1}}}
  end

  def handle_call(:resume_clock, _from, %{running: %{pauses: 0}} = state),
    do: {:reply, :ok, state}

  def handle_call(:resume_clock, _from, %{running: %{pauses: 1} = running} = state),
    do: {:reply, :ok, %{state | running: start_timer(%{running | pauses: 0}, running.remaining)}}

  def handle_call(:resume_clock, _from, %{running: running} = state),
    do: {:reply, :ok, %{state | running: %{running | pauses: running.pauses - 1}}}

  defp start_turn(%{running: running} = state, _input, _options, _client_turn_id, _from)
       when running != nil,
       do: {:reply, {:error, :turn_in_progress}, state}

  defp start_turn(state, input, options, client_turn_id, from) do
    handler = state.handler
    history = History.all(state.session_id)
    marked = is_binary(client_turn_id) and resumable?(handler)

    handler_options =
      options
      |> Keyword.put(:session_id, state.session_id)
      |> Keyword.put(:checkpoint, checkpoint(state.session_id, 0))

    turn = Turn.start(input, client_turn_id, turn_options(options))

    # The marker is written before the turn, so a turn that can continue is never recorded without
    # the marker that lets recovery find it; a marker that cannot be written refuses the turn.
    with :ok <- mark(state, marked),
         :ok <- History.append(state.session_id, turn) do
      task =
        Task.Supervisor.async(Mead.TurnSupervisor, fn ->
          handler.handle_turn(history, input, handler_options)
        end)

      {:noreply,
       %{state | running: new_running(task, [waiter(from)], marked, state.turn_timeout)}}
    else
      {:error, _reason} = error ->
        if marked, do: clear_marker(state)
        {:reply, error, state}
    end
  end

  defp mark(_state, false), do: :ok

  defp mark(state, true) do
    settings = %{handler: state.handler, turn_timeout: state.turn_timeout}

    case Pending.mark(state.directory, state.session_id, settings) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  defp new_running(task, waiters, marked, turn_timeout) do
    start_timer(
      %{waiters: waiters, task: task, generation: 0, pauses: 0, marked: marked},
      turn_timeout
    )
  end

  # A waiter is monitored, so one that dies while the turn runs leaves the list instead of
  # holding a reply nobody will read.
  defp waiter({pid, _tag} = from), do: {from, Process.monitor(pid)}

  # The newest turn recorded under the key; a key is recorded once, because a second use never
  # starts a turn.
  #
  # A turn found :in_progress while no turn runs would be replied as {:error, :in_progress}. That
  # state cannot be reached: init/1 either continues such a turn (a task runs it from
  # handle_continue/2, before any submit is handled) or marks it interrupted (in memory even when
  # the write fails), and the history restarting restarts the server too (rest_for_one). A change
  # to any of those must keep that true.
  defp earlier_turn(_session_id, nil), do: nil

  defp earlier_turn(session_id, client_turn_id),
    do: History.find_by_client_turn_id(session_id, client_turn_id)

  defp conflict_details(turn) do
    %{
      client_turn_id: turn.client_turn_id,
      input: turn.input,
      status: turn.status,
      started_at: turn.started_at
    }
  end

  @impl true
  def handle_info({reference, result}, %{running: %{task: %Task{ref: reference}}} = state) do
    Process.demonitor(reference, [:flush])
    conclude(state, normalize(result))
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{running: %{task: %Task{ref: reference}}} = state
      ) do
    conclude(state, {:failed, reason})
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{running: running} = state)
      when running != nil do
    waiters = Enum.reject(running.waiters, fn {_from, monitor} -> monitor == reference end)
    {:noreply, %{state | running: %{running | waiters: waiters}}}
  end

  def handle_info(
        {:turn_timeout, reference, generation},
        %{running: %{task: %Task{ref: reference} = task, generation: generation}} = state
      ) do
    case kill_task(task) do
      {:ok, result} -> conclude(state, normalize(result))
      {:exit, reason} -> conclude(state, {:failed, reason})
      nil -> conclude(state, {:timeout, nil})
    end
  end

  # Exit signals from finished tasks, and late timers or replies from a turn that concluded or
  # from a timer generation that a pause replaced.
  def handle_info(_stray_message, state), do: {:noreply, state}

  # Each timer carries a generation, so a timeout message that was already on its way when a pause
  # cancelled the timer can never end the turn after the clock restarted.
  defp start_timer(running, milliseconds) do
    generation = running.generation + 1

    timer =
      Process.send_after(self(), {:turn_timeout, running.task.ref, generation}, milliseconds)

    running
    |> Map.merge(%{timer: timer, generation: generation, deadline: now() + milliseconds})
    |> Map.put(:remaining, nil)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Task.shutdown/2 monitors the pid again, and for a task that already died that second monitor
  # answers :noproc and the task's real exit reason is thrown away. The monitor taken when the
  # task started always delivers the real reason, so wait on that one.
  defp kill_task(%Task{pid: pid, ref: reference}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^reference, :process, _pid, reason} ->
        receive do
          {^reference, result} -> {:ok, result}
        after
          0 -> if reason == :killed, do: nil, else: {:exit, reason}
        end
    end
  end

  defp normalize({:ok, output}), do: {:ok, output}
  defp normalize({:error, reason}), do: {:failed, reason}
  defp normalize(other), do: {:failed, {:bad_return, other}}

  defp conclude(state, {status, output} = outcome) do
    %{waiters: waiters, timer: timer, marked: marked} = state.running

    if timer, do: Process.cancel_timer(timer)

    record(
      History.update_last(state.session_id, &Turn.finish(&1, status, output)),
      state.session_id
    )

    if marked, do: clear_marker(state)

    reply = reply_for(outcome)

    Enum.each(waiters, fn {from, monitor} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, reply)
    end)

    {:noreply, %{state | running: nil}}
  end

  # The caller already has the answer, so a failed write is logged and never replaces the reply.
  defp record(:ok, _session_id), do: :ok

  defp record({:error, reason}, session_id) do
    Logger.error("could not record the history of session #{session_id}: #{inspect(reason)}")
  end

  defp reply_for({:ok, output}), do: {:ok, output}
  defp reply_for({:failed, reason}), do: {:error, {:failed, reason}}
  defp reply_for({status, _output}), do: {:error, status}
end
