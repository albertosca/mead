defmodule Mead.Test.FakeInteraction do
  @moduledoc false
  @behaviour Mead.Router.Interaction

  # Records every callback as a message to the test process and answers permission requests from a
  # script held in an Agent: a list of answers consumed in order, `:allow` once it runs out.
  # The context is `%{test_pid: pid, script: agent}`.

  def start(answers) do
    {:ok, script} = Agent.start_link(fn -> answers end)
    %{test_pid: self(), script: script}
  end

  @impl true
  def request_permission(context, request) do
    send(context.test_pid, {:request_permission, request})

    Agent.get_and_update(context.script, fn
      [answer | rest] -> {answer, rest}
      [] -> {:allow, []}
    end)
  end

  @impl true
  def register_call(context, tool_call_id, pid) do
    send(context.test_pid, {:register_call, tool_call_id, pid})
    :ok
  end

  @impl true
  def tool_updated(context, update) do
    send(context.test_pid, {:tool_updated, update})
    :ok
  end
end
