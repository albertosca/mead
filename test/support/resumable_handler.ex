defmodule Mead.Test.ResumableHandler do
  @moduledoc false

  # A turn handler that can continue. The input `{:checkpointed, test_pid, wanted}` records the
  # steps of `wanted` one at a time through the `:checkpoint` option; after each one it tells the
  # test `{:handler_at, pid, steps_so_far}` and waits for `:release`. A continued turn first tells
  # the test `{:resumed_with, steps}` and records only the steps still missing. `{:echo, text}`
  # answers at once.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, input, options), do: run(input, [], options)

  @impl true
  def resume_turn(_history, {:checkpointed, test_pid, _wanted} = input, steps, options) do
    send(test_pid, {:resumed_with, steps})
    run(input, steps, options)
  end

  def resume_turn(_history, input, steps, options), do: run(input, steps, options)

  defp run({:echo, text}, _steps, _options), do: {:ok, text}

  defp run({:checkpointed, test_pid, wanted}, steps, options) do
    send(test_pid, {:handler_options, options})

    record(
      test_pid,
      Enum.drop(wanted, length(steps)),
      steps,
      Keyword.fetch!(options, :checkpoint)
    )
  end

  defp record(_test_pid, [], steps, _checkpoint), do: {:ok, steps}

  defp record(test_pid, [step | rest], steps, checkpoint) do
    case checkpoint.(step) do
      :ok ->
        steps = steps ++ [step]
        send(test_pid, {:handler_at, self(), steps})

        receive do
          :release -> record(test_pid, rest, steps, checkpoint)
        end

      {:error, reason} ->
        {:error, {:checkpoint_failed, reason}}
    end
  end
end
