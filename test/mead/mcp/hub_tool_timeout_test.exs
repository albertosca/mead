defmodule Mead.MCP.HubToolTimeoutTest do
  # Not async: the tool timeout is read from the application environment.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.MCP.Hub
  alias Mead.Test.FakeTransport

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:mead, :mcp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mead, :mcp, previous),
        else: Application.delete_env(:mead, :mcp)
    end)
  end

  defp put_tool_timeout(value), do: Application.put_env(:mead, :mcp, tool_timeout: value)

  defp start_connected_hub do
    name = :"hub_#{System.unique_integer([:positive])}"

    options = [
      name: name,
      servers: [files: [transport: {:stdio, command: "unused"}, tools: [read_file: :read]]],
      transports: %{stdio: {FakeTransport, [test_pid: self()]}},
      reconnect_delays: [10],
      handshake_timeout: 10_000
    ]

    start_supervised!(Supervisor.child_spec({Hub, options}, id: name))

    transport =
      receive do
        {:transport_started, transport} ->
          tool = %{
            "name" => "read_file",
            "description" => "reads",
            "inputSchema" => %{"type" => "object"}
          }

          FakeTransport.complete_handshake(transport, [tool])
          transport
      after
        10_000 -> raise "no transport was started"
      end

    wait_until(fn -> Hub.tools_for([], name) != [] end)
    {name, transport}
  end

  test "defaults to 15 seconds" do
    Application.delete_env(:mead, :mcp)
    assert Hub.tool_timeout() == 15_000
  end

  test "reads a positive integer from the :mcp configuration" do
    put_tool_timeout(120_000)
    assert Hub.tool_timeout() == 120_000
  end

  test "refuses a value that is not a positive integer within the maximum" do
    for bad <- [0, -1, 1.5, "60", nil, 3_600_001] do
      put_tool_timeout(bad)
      assert_raise ArgumentError, ~r/tool_timeout/, fn -> Hub.tool_timeout() end
    end
  end

  test "a call that outlives a short configured timeout reports :timeout" do
    put_tool_timeout(100)
    {hub, _transport} = start_connected_hub()

    {microseconds, result} =
      :timer.tc(fn -> Hub.call_tool("files__read_file", %{}, [], hub) end)

    assert result == {:error, :timeout}
    assert microseconds < 2_000_000
  end

  test "a call slower than the default still succeeds under a longer configured timeout" do
    put_tool_timeout(5_000)
    {hub, transport} = start_connected_hub()

    task = Task.async(fn -> Hub.call_tool("files__read_file", %{}, [], hub) end)
    request = FakeTransport.next_request(transport)
    Process.sleep(300)

    FakeTransport.reply(transport, request, %{
      "content" => [%{"type" => "text", "text" => "late but fine"}]
    })

    assert Task.await(task) == {:ok, %{content: "late but fine", is_error: false}}
  end
end
