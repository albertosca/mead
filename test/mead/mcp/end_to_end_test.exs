defmodule Mead.MCP.EndToEndTest.Hub do
  @moduledoc false

  # Points the router at a hub with its own name, since the application owns the default one.
  def tools_for(options), do: Mead.MCP.Hub.tools_for(options, :end_to_end_hub)

  def call_tool(name, arguments, options),
    do: Mead.MCP.Hub.call_tool(name, arguments, options, :end_to_end_hub)
end

defmodule Mead.MCP.EndToEndTest do
  # Starts a real `elixir` child process, so it is not worth running alongside other process tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.MCP.EndToEndTest.Hub, as: TestHub
  alias Mead.MCP.Hub
  alias Mead.Router
  alias Mead.Test.FakeProvider

  @moduletag :capture_log
  @stub Path.expand("../../support/stub_mcp_server.exs", __DIR__)
  # An argument the stub ignores, unique to this run, so the process check never sees a stub that
  # another session or an earlier run started from the same file.
  @marker "end-to-end-#{System.unique_integer([:positive])}-#{System.os_time()}"

  defp start_hub(servers, extra \\ []) do
    start_supervised!(
      {Hub, [name: :end_to_end_hub, servers: servers, reconnect_delays: [50]] ++ extra}
    )
  end

  defp stub_server do
    [
      stub: [
        transport:
          {:stdio, command: System.find_executable("elixir"), arguments: [@stub, @marker]},
        tools: [echo: :read, fail: :read, write_note: :effect]
      ]
    ]
  end

  defp names(options \\ []) do
    :end_to_end_hub |> then(&Hub.tools_for(options, &1)) |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "a real stdio server is connected, filtered by the policy, and called" do
    start_hub(stub_server())
    wait_until(fn -> names() != [] end, 60_000)

    assert names() == ["stub__echo", "stub__fail"]
    assert names(tools: :effect) == ["stub__echo", "stub__fail", "stub__write_note"]

    assert Hub.call_tool("stub__echo", %{"text" => "hi"}, [], :end_to_end_hub) ==
             {:ok, %{content: "hi", is_error: false}}

    assert Hub.call_tool("stub__fail", %{}, [], :end_to_end_hub) ==
             {:ok, %{content: "it failed", is_error: true}}
  end

  test "an effect tool needs the opt-in, and the server's own annotations grant nothing" do
    start_hub(stub_server())
    wait_until(fn -> names() != [] end, 60_000)

    assert Hub.call_tool("stub__write_note", %{}, [], :end_to_end_hub) == {:error, :not_allowed}

    assert Hub.call_tool("stub__write_note", %{}, [tools: :effect], :end_to_end_hub) ==
             {:ok, %{content: "note written", is_error: false}}

    refute "stub__secret" in names(tools: :effect)

    assert Hub.call_tool("stub__secret", %{}, [tools: :effect], :end_to_end_hub) ==
             {:error, :unknown_tool}
  end

  test "a configured command that does not exist leaves the hub up, retrying, and the other server working" do
    start_hub(
      [
        broken: [
          transport: {:stdio, command: "definitely-not-a-command-xyz"},
          tools: [anything: :read]
        ]
      ] ++ stub_server()
    )

    wait_until(fn -> names() != [] end, 60_000)

    assert names() == ["stub__echo", "stub__fail"]
    assert Process.alive?(Process.whereis(:end_to_end_hub))
    assert Process.alive?(Process.whereis(Mead.Supervisor))
  end

  test "stopping the hub leaves no stub server behind" do
    start_hub(stub_server())
    wait_until(fn -> names() != [] end, 60_000)

    assert os_pids() != []

    stop_supervised!(Hub)

    wait_until(fn -> os_pids() == [] end, 60_000)
  end

  test "the router runs a whole turn through the real hub" do
    start_hub(stub_server())
    wait_until(fn -> names() != [] end, 60_000)

    {:ok, script} =
      Agent.start_link(fn ->
        [
          FakeProvider.tool_step([{"toolu_1", "stub__echo", %{"text" => "from the model"}}]),
          FakeProvider.text_step("The tool said so.")
        ]
      end)

    slots = [cloud: {FakeProvider, test_pid: self(), script: script}]

    assert Router.route([], "echo something", [route: :cloud], slots, TestHub) ==
             {:ok, "The tool said so."}

    assert_received {:provider_conversed, _first, tools}
    assert Enum.map(tools, & &1.name) |> Enum.sort() == ["stub__echo", "stub__fail"]

    assert_received {:provider_conversed, second, _tools}

    assert %{content: [%{tool_use_id: "toolu_1", content: "from the model", is_error: false}]} =
             List.last(second)
  end

  defp os_pids do
    {output, _status} = System.cmd("pgrep", ["-f", @marker], stderr_to_stdout: true)
    output |> String.split("\n", trim: true)
  end
end
