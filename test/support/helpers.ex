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

      :trace.function(session, traced, true, [:local])
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
