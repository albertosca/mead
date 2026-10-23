defmodule Mead.MCP.HubTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.Hub
  alias Mead.Test.FakeTransport

  @moduletag :capture_log

  defp server(name, tools) do
    {name, [transport: {:stdio, command: "unused"}, tools: tools]}
  end

  defp start_hub(servers, extra \\ []) do
    name = :"hub_#{System.unique_integer([:positive])}"

    options =
      [
        name: name,
        servers: servers,
        transports: %{stdio: {FakeTransport, [test_pid: self()]}},
        reconnect_delays: [10],
        handshake_timeout: 10_000
      ] ++ extra

    start_supervised!(Supervisor.child_spec({Hub, options}, id: name))
    name
  end

  defp raw_tool(name),
    do: %{
      "name" => name,
      "description" => "about #{name}",
      "inputSchema" => %{"type" => "object"}
    }

  defp connect(tools) do
    receive do
      {:transport_started, transport} ->
        FakeTransport.complete_handshake(transport, tools)
        transport
    after
      10_000 -> raise "no transport was started"
    end
  end

  defp tool_names(hub, options \\ []) do
    hub |> then(&Hub.tools_for(options, &1)) |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "an empty configuration is a valid hub with nothing in it" do
    hub = start_hub([])

    assert Hub.tools_for([], hub) == []
    assert Hub.call_tool("a__b", %{}, [], hub) == {:error, :unknown_tool}
  end

  test "a hub that is not running offers no tools and cannot call" do
    assert Hub.tools_for([], :no_such_hub) == []
    assert Hub.call_tool("a__b", %{}, [], :no_such_hub) == {:error, :hub_unavailable}
  end

  test "an invalid configuration refuses to start, with a message that names the problem" do
    assert {:error, reason} =
             start_supervised(
               {Hub, name: :bad_hub, servers: [my_server: [transport: {:stdio, command: "x"}]]}
             )

    assert inspect(reason) =~ "invalid_server_name"
  end

  test "shows the model the listed read tools as server__tool, in the shape a provider expects" do
    hub = start_hub([server(:files, read_file: :read, write_file: :effect)])
    connect([raw_tool("read_file"), raw_tool("write_file"), raw_tool("delete_all")])
    wait_until(fn -> tool_names(hub) != [] end)

    assert Hub.tools_for([], hub) == [
             %{
               name: "files__read_file",
               description: "about read_file",
               input_schema: %{"type" => "object"}
             }
           ]
  end

  test "effect tools appear only with the turn opt-in, and never an unlisted one" do
    hub = start_hub([server(:files, read_file: :read, write_file: :effect)])
    connect([raw_tool("read_file"), raw_tool("write_file"), raw_tool("delete_all")])
    wait_until(fn -> tool_names(hub) != [] end)

    assert tool_names(hub, tools: :effect) == ["files__read_file", "files__write_file"]
  end

  test "routes an allowed call to its server and returns the text" do
    hub = start_hub([server(:files, read_file: :read)])
    transport = connect([raw_tool("read_file")])
    wait_until(fn -> tool_names(hub) != [] end)

    task = Task.async(fn -> Hub.call_tool("files__read_file", %{"path" => "/a"}, [], hub) end)

    request = FakeTransport.next_request(transport)
    assert request["params"] == %{"name" => "read_file", "arguments" => %{"path" => "/a"}}

    FakeTransport.reply(transport, request, %{
      "content" => [%{"type" => "text", "text" => "contents"}]
    })

    assert Task.await(task) == {:ok, %{content: "contents", is_error: false}}
  end

  test "an effect call without the opt-in is refused and nothing is sent" do
    hub = start_hub([server(:files, write_file: :effect)])
    transport = connect([raw_tool("write_file")])
    wait_until(fn -> tool_names(hub, tools: :effect) != [] end)

    assert Hub.call_tool("files__write_file", %{"path" => "/a"}, [], hub) ==
             {:error, :not_allowed}

    assert Hub.call_tool("files__write_file", %{}, [tools: :everything], hub) ==
             {:error, :not_allowed}

    assert_raise RuntimeError, fn -> FakeTransport.next_request(transport, 100) end
  end

  test "an effect call with the opt-in goes through" do
    hub = start_hub([server(:files, write_file: :effect)])
    transport = connect([raw_tool("write_file")])
    wait_until(fn -> tool_names(hub, tools: :effect) != [] end)

    task = Task.async(fn -> Hub.call_tool("files__write_file", %{}, [tools: :effect], hub) end)
    request = FakeTransport.next_request(transport)

    FakeTransport.reply(transport, request, %{
      "content" => [%{"type" => "text", "text" => "written"}]
    })

    assert Task.await(task) == {:ok, %{content: "written", is_error: false}}
  end

  test "names the model was never shown never reach a server" do
    hub = start_hub([server(:files, read_file: :read)])
    transport = connect([raw_tool("read_file"), raw_tool("delete_all")])
    wait_until(fn -> tool_names(hub) != [] end)

    for name <- [
          "delete_all",
          "files__delete_all",
          "ghost__read_file",
          "files__",
          "",
          nil,
          :files__read_file
        ] do
      assert Hub.call_tool(name, %{}, [tools: :effect], hub) == {:error, :unknown_tool}
    end

    assert_raise RuntimeError, fn -> FakeTransport.next_request(transport, 100) end
  end

  test "arguments that are not an object are refused before anything is sent" do
    hub = start_hub([server(:files, read_file: :read)])
    transport = connect([raw_tool("read_file")])
    wait_until(fn -> tool_names(hub) != [] end)

    for arguments <- [nil, "path", ["a"], 1] do
      assert Hub.call_tool("files__read_file", arguments, [], hub) == {:error, :invalid_arguments}
    end

    assert_raise RuntimeError, fn -> FakeTransport.next_request(transport, 100) end
  end

  test "when a server goes away its tools disappear from what the model is shown" do
    hub = start_hub([server(:files, read_file: :read)])
    transport = connect([raw_tool("read_file")])
    wait_until(fn -> tool_names(hub) != [] end)

    FakeTransport.close(transport, {:exit_status, 1})

    wait_until(fn -> tool_names(hub) == [] end)
  end

  test "a server that cannot start does not stop the others, or the hub" do
    hub =
      start_hub(
        [server(:broken, read_file: :read), server(:good, read_file: :read)],
        transports: %{stdio: {FakeTransport, [test_pid: self()]}}
      )

    transport = connect([raw_tool("read_file")])
    assert is_pid(transport)
    assert Process.alive?(Process.whereis(hub))
  end

  test "two servers may expose the same tool name" do
    hub = start_hub([server(:a, search: :read), server(:b, search: :read)])
    connect([raw_tool("search")])
    connect([raw_tool("search")])

    wait_until(fn -> tool_names(hub) == ["a__search", "b__search"] end)
  end

  test "two hubs do not share tools" do
    first = start_hub([server(:files, read_file: :read)])
    second = start_hub([])
    connect([raw_tool("read_file")])
    wait_until(fn -> tool_names(first) != [] end)

    assert tool_names(second) == []
  end
end
