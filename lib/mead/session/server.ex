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

  When the server restarts after a crash, `init/1` marks every turn still recorded as in
  progress as interrupted. A reader that bypasses the server can observe the old status in the
  moment between the new server registering its name and finishing `init/1`.
  """

  use GenServer

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

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(options, :session_id)
    History.mark_interrupted(session_id)

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

    History.append(state.session_id, Turn.start(input))

    task =
      Task.Supervisor.async(Mead.TurnSupervisor, fn ->
        handler.handle_turn(history, input, handler_options)
      end)

    timer = Process.send_after(self(), {:turn_timeout, task.ref}, state.turn_timeout)

    {:noreply, %{state | running: %{from: from, task: task, timer: timer}}}
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

  def handle_info(
        {:turn_timeout, reference},
        %{running: %{task: %Task{ref: reference} = task}} = state
      ) do
    case kill_task(task) do
      {:ok, result} -> conclude(state, normalize(result))
      {:exit, reason} -> conclude(state, {:failed, reason})
      nil -> conclude(state, {:timeout, nil})
    end
  end

  # Exit signals from finished tasks, and late timers or replies from a turn that concluded.
  def handle_info(_stray_message, state), do: {:noreply, state}

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

    Process.cancel_timer(timer)
    History.update_last(state.session_id, &Turn.finish(&1, status, output))
    GenServer.reply(from, reply_for(outcome))

    {:noreply, %{state | running: nil}}
  end

  defp reply_for({:ok, output}), do: {:ok, output}
  defp reply_for({:failed, reason}), do: {:error, {:failed, reason}}
  defp reply_for({status, _output}), do: {:error, status}
end
