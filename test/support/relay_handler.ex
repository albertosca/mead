defmodule Mead.Test.RelayHandler do
  @moduledoc false

  # A turn handler that drives the interaction its options carry, from the turn task, the way the
  # router does. The input `{:relay, test_pid, actions}` runs the actions in order and reports
  # each answer as `{:relay_answer, action, answer, continued?, monotonic_ms}`:
  #
  #   * `:block` (first attempt only) records a step, tells the test `{:relay_blocked, pid}` and
  #     waits for `:release`; a continuation skips it.
  #   * `:permission`, `:choice`, `:tool_updated`, `:register_call`, `{:delta, text}` call the
  #     interaction.
  #
  # Every attempt first tells the test `{:relay_options, interaction}` with the interaction it got.

  @behaviour Mead.Session.TurnHandler

  @request %{
    tool_call_id: "call-1",
    tool: "read_file",
    server: "files",
    class: :read,
    arguments: %{}
  }

  @choice %{
    tool_call_id: "ask-1",
    prompt: "Which?",
    options: [%{id: "a", label: "A"}],
    allow_free_text: false
  }

  @update %{
    tool_call_id: "call-1",
    title: "read_file",
    status: :pending,
    current_step: nil,
    progress: nil,
    cancellable: false
  }

  @impl true
  def handle_turn(_history, input, options), do: run(input, options, false)

  @impl true
  def resume_turn(_history, input, _steps, options), do: run(input, options, true)

  defp run({:relay, test_pid, actions}, options, continued) do
    send(test_pid, {:relay_options, Keyword.get(options, :interaction)})
    Enum.each(actions, &act(&1, test_pid, options, continued))
    {:ok, "done"}
  end

  defp act(:block, _test_pid, _options, true), do: :ok

  defp act(:block, test_pid, options, false) do
    :ok = Keyword.fetch!(options, :checkpoint).(:blocked)
    send(test_pid, {:relay_blocked, self()})

    receive do
      :release -> :ok
    end
  end

  defp act(action, test_pid, options, continued) do
    {module, context} = Keyword.fetch!(options, :interaction)
    answer = call(module, context, action)

    send(
      test_pid,
      {:relay_answer, action, answer, continued, System.monotonic_time(:millisecond)}
    )
  end

  defp call(module, context, :permission), do: module.request_permission(context, @request)
  defp call(module, context, :choice), do: module.ask_choice(context, @choice)
  defp call(module, context, :tool_updated), do: module.tool_updated(context, @update)
  defp call(module, context, :register_call), do: module.register_call(context, "call-1", self())
  defp call(module, context, {:delta, text}), do: module.text_delta(context, text)
end
