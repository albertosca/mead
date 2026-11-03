defmodule Mead.TestHelpers do
  @moduledoc false

  @doc """
  Polls `condition` every 10 ms until it returns a truthy value and returns that value.

  Raises when the value is still falsy after `timeout` milliseconds, so a test fails loudly
  instead of passing on a condition that never held.
  """
  @spec wait_until((-> term()), non_neg_integer()) :: term()
  def wait_until(condition, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(condition, deadline)
  end

  defp poll(condition, deadline) do
    case condition.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "condition was not met before the timeout"
        else
          Process.sleep(10)
          poll(condition, deadline)
        end

      value ->
        value
    end
  end

  @doc """
  Kills the session's server each time its handler announces `{:handler_started, pid}`, until the
  turn has started `starts` times, and waits for the server that replaces the last one. With the
  default 4, a turn whose handler resumes by running again spends its crash budget of 3 and the
  next start ends it interrupted.
  """
  def crash_until_interrupted(session_id, starts \\ 4) do
    for _start <- 1..starts do
      receive do
        {:handler_started, _pid} -> :ok
      after
        10_000 -> raise "the handler did not start"
      end

      old_server = Mead.Session.whereis(session_id, :server)
      Process.exit(old_server, :kill)
      wait_until(fn -> Mead.Session.whereis(session_id, :server) not in [nil, old_server] end)
    end

    wait_until(fn -> match?({:ok, [%{status: :interrupted} | _]}, Mead.history(session_id)) end)
  end

  @doc """
  Waits until the root supervisor can take `free` more restarts without reaching its intensity.

  Every test that kills a root child spends one of the 10 restarts the root allows in 5 seconds,
  and the tests that do so run back to back; without this wait, a seed that orders enough of them
  together takes the whole application down and fails every test after it. A restart counts while
  it is younger than the period, in whole seconds, as `:supervisor` counts it.
  """
  @spec await_root_restart_budget(pos_integer()) :: :ok
  def await_root_restart_budget(free) do
    wait_until(fn -> root_restarts_left() >= free end, 7_000)
    :ok
  end

  # The supervisor's state record, as of OTP 29: {:state, name, strategy, children, dynamics,
  # intensity, period, restarts, ...}, where restarts are monotonic times in seconds.
  defp root_restarts_left do
    {:state, _name, _strategy, _children, _dynamics, intensity, period, restarts} =
      Mead.Supervisor |> :sys.get_state() |> Tuple.to_list() |> Enum.take(8) |> List.to_tuple()

    threshold = System.monotonic_time(:second) - period
    intensity - Enum.count(restarts, &(&1 >= threshold))
  end

  @doc """
  Runs `function` in a fresh process and returns every `{module, function, arguments}` call it
  made to `traced`, in order.

  The trace lives in its own trace session, so it neither sees nor disturbs the calls other
  tests trace, even of the same function and at the same time.
  """
  @spec calls_to(mfa(), (-> term())) :: [{module(), atom(), [term()]}]
  def calls_to({module, name, arity} = traced, function) do
    test_process = self()
    session = :trace.session_create(:calls_to, test_process, [])

    try do
      worker =
        spawn(fn ->
          receive do
            :go ->
              function.()
              send(test_process, {:calls_to_done, self()})
          end
        end)

      # A pattern on a module that is not loaded yet matches nothing and traces nothing, so a
      # test run on its own, before anything else loaded the module, would see no calls at all.
      Code.ensure_loaded!(module)

      if :trace.function(session, traced, true, [:local]) == 0 do
        raise ArgumentError, "#{inspect(traced)} matches no function, so no call can be traced"
      end

      :trace.process(session, worker, true, [:call])
      send(worker, :go)

      receive do
        {:calls_to_done, ^worker} -> :ok
      after
        5_000 -> raise "the traced function did not finish"
      end

      # Trace messages may still be on their way when the worker says it is done; this waits
      # until every one it caused has arrived.
      delivered = :trace.delivered(session, worker)

      receive do
        {:trace_delivered, ^worker, ^delivered} -> :ok
      after
        5_000 -> raise "the trace messages were not delivered"
      end

      for {:trace, ^worker, :call, {^module, ^name, arguments}} <- traces(worker),
          length(arguments) == arity,
          do: {module, name, arguments}
    after
      :trace.session_destroy(session)
    end
  end

  defp traces(worker, collected \\ []) do
    receive do
      {:trace, ^worker, :call, _call} = trace -> traces(worker, [trace | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end
end
