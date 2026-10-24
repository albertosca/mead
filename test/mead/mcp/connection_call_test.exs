defmodule Mead.MCP.ConnectionCallTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.{Catalog, Connection}
  alias Mead.Test.FakeTransport

  @moduletag :capture_log

  setup do
    suffix = System.unique_integer([:positive])
    registry = :"call_registry_#{suffix}"
    catalog = :"call_catalog_#{suffix}"
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Catalog, name: catalog, servers: []})

    connection =
      start_supervised!({
        Connection,
        # Far longer than a test runs: a reconnect in the middle of a test would put its own
        # handshake request into `pending`.
        server: :fake,
        registry: registry,
        catalog: catalog,
        transport: {FakeTransport, [test_pid: self()]},
        reconnect_delays: [60_000],
        handshake_timeout: 10_000
      })

    transport =
      receive do
        {:transport_started, transport} -> transport
      after
        10_000 -> raise "no transport was started"
      end

    FakeTransport.complete_handshake(transport, [
      %{"name" => "echo", "inputSchema" => %{"type" => "object"}}
    ])

    wait_until(fn -> match?({:ok, [_ | _], _servers}, Catalog.snapshot(catalog)) end)

    %{registry: registry, catalog: catalog, connection: connection, transport: transport}
  end

  defp call(context, arguments \\ %{"text" => "hi"}, timeout \\ 30_000) do
    Connection.call_tool(context.registry, :fake, "echo", arguments, timeout)
  end

  defp text_result(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  test "a successful call sends tools/call and returns the text", context do
    task = Task.async(fn -> call(context) end)

    request = FakeTransport.next_request(context.transport)
    assert request["method"] == "tools/call"
    assert request["params"] == %{"name" => "echo", "arguments" => %{"text" => "hi"}}
    FakeTransport.reply(context.transport, request, text_result("hello"))

    assert Task.await(task) == {:ok, %{content: "hello", is_error: false}}
  end

  test "joins several text blocks with a newline", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)

    FakeTransport.reply(context.transport, request, %{
      "content" => [%{"type" => "text", "text" => "one"}, %{"type" => "text", "text" => "two"}]
    })

    assert Task.await(task) == {:ok, %{content: "one\ntwo", is_error: false}}
  end

  test "a tool that reports isError is a normal result flagged as an error", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)

    FakeTransport.reply(context.transport, request, %{
      "content" => [%{"type" => "text", "text" => "ENOENT"}],
      "isError" => true
    })

    assert Task.await(task) == {:ok, %{content: "ENOENT", is_error: true}}
  end

  test "isError only counts when it is exactly true", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)

    FakeTransport.reply(context.transport, request, %{
      "content" => [%{"type" => "text", "text" => "fine"}],
      "isError" => "yes"
    })

    assert {:ok, %{is_error: false}} = Task.await(task)
  end

  test "non-text blocks become placeholders instead of failing", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)

    FakeTransport.reply(context.transport, request, %{
      "content" => [
        %{"type" => "text", "text" => "caption"},
        %{"type" => "image", "data" => "AAAA", "mimeType" => "image/png"},
        %{"nonsense" => true}
      ]
    })

    assert Task.await(task) ==
             {:ok,
              %{
                content: "caption\n[non-text content: image]\n[non-text content]",
                is_error: false
              }}
  end

  test "a result longer than 50 000 characters is truncated with a marker", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)
    FakeTransport.reply(context.transport, request, text_result(String.duplicate("x", 80_000)))

    assert {:ok, %{content: content, is_error: false}} = Task.await(task)
    assert String.starts_with?(content, String.duplicate("x", 50_000))
    assert String.ends_with?(content, "[truncated: the result was longer than 50000 characters]")
    assert String.length(content) < 50_100
  end

  test "a result of exactly 50 000 characters is not truncated", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)
    FakeTransport.reply(context.transport, request, text_result(String.duplicate("x", 50_000)))

    assert {:ok, %{content: content}} = Task.await(task)
    assert content == String.duplicate("x", 50_000)
  end

  test "a JSON-RPC error is returned with its code and message", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)

    FakeTransport.deliver(
      context.transport,
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: request["id"],
        error: %{code: -32_602, message: "Tool x not found"}
      })
    )

    assert Task.await(task) == {:error, {:rpc_error, -32_602, "Tool x not found"}}
  end

  test "a result without content is malformed", context do
    task = Task.async(fn -> call(context) end)
    request = FakeTransport.next_request(context.transport)
    FakeTransport.reply(context.transport, request, %{"unexpected" => true})

    assert Task.await(task) == {:error, :malformed_response}
  end

  test "an answer that never comes times out, and a late answer is harmless", context do
    task = Task.async(fn -> call(context, %{}, 50) end)
    request = FakeTransport.next_request(context.transport)

    assert Task.await(task) == {:error, :timeout}
    assert :sys.get_state(context.connection).pending == %{}

    FakeTransport.reply(context.transport, request, text_result("too late"))
    Process.sleep(30)
    assert Process.alive?(context.connection)

    next = Task.async(fn -> call(context) end)
    second = FakeTransport.next_request(context.transport)
    FakeTransport.reply(context.transport, second, text_result("fresh"))
    assert Task.await(next) == {:ok, %{content: "fresh", is_error: false}}
  end

  test "two callers at once each get their own answer, even out of order", context do
    first = Task.async(fn -> call(context, %{"n" => 1}) end)
    first_request = FakeTransport.next_request(context.transport)
    second = Task.async(fn -> call(context, %{"n" => 2}) end)
    second_request = FakeTransport.next_request(context.transport)

    assert first_request["id"] != second_request["id"]

    FakeTransport.reply(context.transport, second_request, text_result("answer for 2"))
    FakeTransport.reply(context.transport, first_request, text_result("answer for 1"))

    assert Task.await(first) == {:ok, %{content: "answer for 1", is_error: false}}
    assert Task.await(second) == {:ok, %{content: "answer for 2", is_error: false}}
  end

  test "a caller that dies mid-call leaves no pending request, and its late answer is ignored",
       context do
    caller = spawn(fn -> call(context, %{}, 5_000) end)
    request = FakeTransport.next_request(context.transport)
    assert map_size(:sys.get_state(context.connection).pending) == 1

    Process.exit(caller, :kill)

    wait_until(fn -> :sys.get_state(context.connection).pending == %{} end)

    FakeTransport.reply(context.transport, request, text_result("nobody is listening"))
    Process.sleep(30)
    assert Process.alive?(context.connection)
  end

  test "a transport that closes mid-call fails the caller with :connection_lost", context do
    task = Task.async(fn -> call(context) end)
    _request = FakeTransport.next_request(context.transport)

    FakeTransport.close(context.transport, {:exit_status, 1})

    assert Task.await(task) == {:error, :connection_lost}
    assert :sys.get_state(context.connection).pending == %{}
  end

  test "a send that fails reports it to the caller", context do
    FakeTransport.fail_sends(context.transport, :closed)

    assert call(context) == {:error, {:send_failed, :closed}}
  end

  test "a call while disconnected is unavailable", context do
    FakeTransport.close(context.transport, :gone)
    wait_until(fn -> :sys.get_state(context.connection).phase == :disconnected end)

    assert call(context) == {:error, :connection_unavailable}
  end

  test "a call to a server that has no connection is unavailable", context do
    assert Connection.call_tool(context.registry, :nobody, "echo", %{}, 100) ==
             {:error, :connection_unavailable}
  end

  test "a connection that dies while a call is in flight fails the caller instead of hanging",
       context do
    task = Task.async(fn -> call(context, %{}, 5_000) end)
    _request = FakeTransport.next_request(context.transport)

    Process.exit(context.connection, :kill)

    assert Task.await(task) == {:error, :connection_lost}
  end
end
