defmodule Mead.MCP.TurnTimeoutTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.Hub
  alias Mead.Test.FakeTransport

  @moduletag :capture_log
  @moduletag timeout: 10_000

  defmodule ToolCallingHandler do
    @moduledoc false

    @behaviour Mead.Session.TurnHandler

    @impl true
    def handle_turn(_history, {:call_tool, hub, name}, _options) do
      case Mead.MCP.Hub.call_tool(name, %{}, [], hub) do
        {:ok, %{content: content}} -> {:ok, content}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_hub do
    name = :"timeout_hub_#{System.unique_integer([:positive])}"

    options = [
      name: name,
      servers: [slow: [transport: {:stdio, command: "unused"}, tools: [wait: :read]]],
      transports: %{stdio: {FakeTransport, [test_pid: self()]}},
      reconnect_delays: [10],
      handshake_timeout: 500
    ]

    start_supervised!(Supervisor.child_spec({Hub, options}, id: name))

    transport =
      receive do
        {:transport_started, transport} -> transport
      after
        1_000 -> raise "no transport was started"
      end

    FakeTransport.complete_handshake(transport, [
      %{"name" => "wait", "inputSchema" => %{"type" => "object"}}
    ])

    wait_until(fn -> Hub.tools_for([], name) != [] end)
    {name, transport}
  end

  defp pending_calls(hub) do
    [{connection, _value}] = Registry.lookup(:"#{hub}.Registry", :slow)
    connection |> :sys.get_state() |> Map.fetch!(:pending) |> map_size()
  end

  test "a turn killed by its timeout mid tool call leaves nothing pending and the hub usable" do
    {hub, transport} = start_hub()
    {:ok, session_id} = Mead.start_session(handler: ToolCallingHandler, turn_timeout: 200)
    on_exit(fn -> Mead.stop_session(session_id) end)

    turn = Task.async(fn -> Mead.submit_turn(session_id, {:call_tool, hub, "slow__wait"}) end)

    stuck_request = FakeTransport.next_request(transport)
    assert stuck_request["method"] == "tools/call"
    assert pending_calls(hub) == 1

    assert Task.await(turn) == {:error, :timeout}

    wait_until(fn -> pending_calls(hub) == 0 end)

    # The late answer for the abandoned call is ignored, and the next turn is served normally.
    FakeTransport.reply(transport, stuck_request, %{
      "content" => [%{"type" => "text", "text" => "too late"}]
    })

    next_turn =
      Task.async(fn -> Mead.submit_turn(session_id, {:call_tool, hub, "slow__wait"}) end)

    next_request = FakeTransport.next_request(transport)
    assert next_request["id"] != stuck_request["id"]

    FakeTransport.reply(transport, next_request, %{
      "content" => [%{"type" => "text", "text" => "on time"}]
    })

    assert Task.await(next_turn) == {:ok, "on time"}
  end
end
