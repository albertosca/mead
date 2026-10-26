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

  The turn clock can be suspended with `pause_clock/1` and `resume_clock/1`, for a turn that waits
  for a person: while at least one pause is open the turn cannot time out, and the last resume
  restarts the timer with the time that was left. Pauses nest by counting, and neither call does
  anything when no turn is running, so a pause can never leak into the next turn.

  When the server restarts after a crash, `init/1` marks every turn still recorded as in
  progress as interrupted. A reader that bypasses the server can observe the old status in the
  moment between the new server registering its name and finishing `init/1`.
  """

  use GenServer

  require Logger

  alias Mead.Session
  alias Mead.Session.History
  alias Mead.Session.Turn

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
      server -> GenServer.call(server, request)
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(options, :session_id)
    record(History.mark_interrupted(session_id), session_id)

    state = %{
      session_id: session_id,
      handler: Keyword.fetch!(options, :handler),
      turn_timeout: Keyword.fetch!(options, :turn_timeout),
      running: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, _input, _options}, _from, %{running: running} = state)
      when running != nil do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:submit, input, options}, from, state) do
    handler = state.handler
    history = History.all(state.session_id)
    handler_options = Keyword.put(options, :session_id, state.session_id)

    case History.append(state.session_id, Turn.start(input)) do
      :ok ->
        task =
          Task.Supervisor.async(Mead.TurnSupervisor, fn ->
            handler.handle_turn(history, input, handler_options)
          end)

        running =
          start_timer(%{from: from, task: task, generation: 0, pauses: 0}, state.turn_timeout)

        {:noreply, %{state | running: running}}

      {:error, _reason} = error ->
        {:reply, error, state}
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
    %{from: from, timer: timer} = state.running

    if timer, do: Process.cancel_timer(timer)

    record(
      History.update_last(state.session_id, &Turn.finish(&1, status, output)),
      state.session_id
    )

    GenServer.reply(from, reply_for(outcome))

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
