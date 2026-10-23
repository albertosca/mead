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
end
