defmodule Mead.RouterOrphanTest do
  # A tool runs in a process the router does not link to, so that cancelling can kill it without
  # killing the turn. That process must still not outlive the turn that started it.
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.{FakeHub, FakeInteraction, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}

  test "a tool process ends when the router process that started it is killed" do
    {:ok, script} =
      Agent.start_link(fn ->
        [
          FakeProvider.tool_step([{"call-1", "files__read_file", %{"path" => "/a"}}]),
          FakeProvider.text_step("done")
        ]
      end)

    slots = [
      cloud: {FakeProvider, test_pid: self(), script: script},
      local: {FakeProvider, test_pid: self(), script: script}
    ]

    test_pid = self()

    router =
      spawn(fn ->
        FakeHub.configure(
          test_pid: test_pid,
          tools: [@tool],
          results: %{"files__read_file" => :block}
        )

        context = FakeInteraction.start([])

        Router.route(
          [],
          "read it",
          [route: :cloud, tools: :effect, interaction: {FakeInteraction, context}],
          slots,
          FakeHub
        )
      end)

    assert_receive {:tool_blocked, tool_process}, 2_000
    monitor = Process.monitor(tool_process)

    Process.exit(router, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^tool_process, :killed}, 2_000
  end
end
