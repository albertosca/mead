defmodule Mead.MCP.ConnectionTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.{Catalog, Connection}
  alias Mead.Test.FakeTransport

  @moduletag :capture_log

  # A handshake normally takes milliseconds, but a loaded machine can stall a process for hundreds
  # of them, so a test that expects the handshake to succeed must not race a short deadline. The
  # tests that are about the deadline itself ask for `@short_timeout`.
  @patient_timeout 10_000
  @short_timeout 300

  setup do
    suffix = System.unique_integer([:positive])
    registry = :"connection_registry_#{suffix}"
    catalog = :"connection_catalog_#{suffix}"
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Catalog, name: catalog, servers: []})

    %{registry: registry, catalog: catalog}
  end

  defp start_connection(context, overrides \\ []) do
    options =
      [
        server: :fake,
        registry: context.registry,
        catalog: context.catalog,
        transport: {FakeTransport, [test_pid: self()]},
        reconnect_delays: [10],
        handshake_timeout: @patient_timeout
      ]
      |> Keyword.merge(overrides)

    start_supervised!({Connection, options})
  end

  defp started_transport do
    receive do
      {:transport_started, transport} -> transport
    after
      10_000 -> raise "no transport was started"
    end
  end

  defp entry_names(catalog) do
    {:ok, entries, _servers} = Catalog.snapshot(catalog)
    entries |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp raw_tool(name),
    do: %{
      "name" => name,
      "description" => "about #{name}",
      "inputSchema" => %{"type" => "object"}
    }

  describe "the handshake" do
    test "initializes with the pinned version, announces itself ready, then lists the tools",
         context do
      start_connection(context)
      transport = started_transport()

      %{initialize: initialize, initialized: initialized, list: list} =
        FakeTransport.complete_handshake(transport, [raw_tool("read_file")])

      assert initialize["method"] == "initialize"
      assert initialize["params"]["protocolVersion"] == "2025-06-18"
      assert initialized["method"] == "notifications/initialized"
      refute Map.has_key?(initialized, "id")
      assert list["method"] == "tools/list"

      wait_until(fn -> entry_names(context.catalog) == ["read_file"] end)

      {:ok, [entry], _servers} = Catalog.snapshot(context.catalog)

      assert entry == %{
               server: :fake,
               name: "read_file",
               description: "about read_file",
               input_schema: %{"type" => "object"}
             }
    end

    test "nothing is published before the tool list arrives", context do
      start_connection(context)
      transport = started_transport()

      initialize = FakeTransport.next_request(transport)
      FakeTransport.reply(transport, initialize, %{"protocolVersion" => "2025-06-18"})
      _initialized = FakeTransport.next_request(transport)
      _list = FakeTransport.next_request(transport)

      Process.sleep(50)
      assert entry_names(context.catalog) == []
    end

    test "follows the cursor through every page of the tool list", context do
      start_connection(context)
      transport = started_transport()

      initialize = FakeTransport.next_request(transport)
      FakeTransport.reply(transport, initialize, %{"protocolVersion" => "2025-06-18"})
      _initialized = FakeTransport.next_request(transport)

      first = FakeTransport.next_request(transport)
      refute Map.has_key?(first["params"], "cursor")

      FakeTransport.reply(transport, first, %{
        "tools" => [raw_tool("a")],
        "nextCursor" => "page-2"
      })

      second = FakeTransport.next_request(transport)
      assert second["params"]["cursor"] == "page-2"
      FakeTransport.reply(transport, second, %{"tools" => [raw_tool("b")]})

      wait_until(fn -> entry_names(context.catalog) == ["a", "b"] end)
    end

    test "skips tools without a usable name, defaults a missing schema, and keeps the first of a duplicate",
         context do
      start_connection(context)
      transport = started_transport()

      FakeTransport.complete_handshake(transport, [
        %{"name" => "", "description" => "empty name"},
        %{"description" => "no name"},
        %{"name" => 5},
        "not a map",
        %{"name" => "plain"},
        %{"name" => "dup", "description" => "first"},
        %{"name" => "dup", "description" => "second"}
      ])

      wait_until(fn -> entry_names(context.catalog) == ["dup", "plain"] end)

      {:ok, entries, _servers} = Catalog.snapshot(context.catalog)
      plain = Enum.find(entries, &(&1.name == "plain"))
      dup = Enum.find(entries, &(&1.name == "dup"))

      assert plain.description == nil
      assert plain.input_schema == %{"type" => "object", "properties" => %{}}
      assert dup.description == "first"
    end

    test "clamps what a server says about a tool before it can reach the model", context do
      start_connection(context)
      transport = started_transport()

      oversized_schema = %{
        "type" => "object",
        "properties" => %{"payload" => %{"description" => String.duplicate("x", 30_000)}}
      }

      FakeTransport.complete_handshake(transport, [
        %{"name" => "wordy", "description" => String.duplicate("d", 5_000)},
        %{
          "name" => "untyped",
          "inputSchema" => %{"properties" => %{"path" => %{"type" => "string"}}}
        },
        %{"name" => "scalar", "inputSchema" => %{"type" => "string"}},
        %{"name" => "huge", "inputSchema" => oversized_schema}
      ])

      wait_until(fn -> entry_names(context.catalog) == ["huge", "scalar", "untyped", "wordy"] end)

      {:ok, entries, _servers} = Catalog.snapshot(context.catalog)
      by_name = Map.new(entries, &{&1.name, &1})
      default_schema = %{"type" => "object", "properties" => %{}}

      assert String.length(by_name["wordy"].description) == 2_000

      assert by_name["untyped"].input_schema == %{
               "type" => "object",
               "properties" => %{"path" => %{"type" => "string"}}
             }

      assert by_name["scalar"].input_schema == default_schema
      assert by_name["huge"].input_schema == default_schema
    end

    test "a tool list that is not a list disconnects and reconnects", context do
      start_connection(context)
      first = started_transport()

      initialize = FakeTransport.next_request(first)
      FakeTransport.reply(first, initialize, %{"protocolVersion" => "2025-06-18"})
      _initialized = FakeTransport.next_request(first)
      list = FakeTransport.next_request(first)
      FakeTransport.reply(first, list, %{"tools" => "nope"})

      second = started_transport()
      assert second != first
      assert entry_names(context.catalog) == []
    end

    test "a server that answers with an unsupported protocol version is disconnected and retried",
         context do
      start_connection(context)
      first = started_transport()

      initialize = FakeTransport.next_request(first)
      FakeTransport.reply(first, initialize, %{"protocolVersion" => "1999-01-01"})

      second = started_transport()
      assert second != first
      assert entry_names(context.catalog) == []
    end

    test "an initialize answer without a version is disconnected and retried", context do
      start_connection(context)
      first = started_transport()

      initialize = FakeTransport.next_request(first)
      FakeTransport.reply(first, initialize, %{})

      assert started_transport() != first
    end

    test "a server that never answers is abandoned after the handshake timeout", context do
      start_connection(context, handshake_timeout: @short_timeout)
      first = started_transport()
      _initialize = FakeTransport.next_request(first)

      assert started_transport() != first
    end

    test "a JSON-RPC error to initialize disconnects and retries", context do
      start_connection(context)
      first = started_transport()
      initialize = FakeTransport.next_request(first)

      FakeTransport.deliver(
        first,
        JSON.encode!(%{
          jsonrpc: "2.0",
          id: initialize["id"],
          error: %{code: -32_600, message: "no"}
        })
      )

      assert started_transport() != first
    end
  end

  describe "losing the server" do
    test "when the transport closes, the tools disappear and the connection comes back",
         context do
      connection = start_connection(context)
      first = started_transport()
      FakeTransport.complete_handshake(first, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.close(first, {:exit_status, 1})

      wait_until(fn -> entry_names(context.catalog) == [] end)

      second = started_transport()
      assert second != first
      assert Process.alive?(connection)

      FakeTransport.complete_handshake(second, [raw_tool("b")])
      wait_until(fn -> entry_names(context.catalog) == ["b"] end)
    end

    test "a transport that cannot start leaves the connection alive and retrying", context do
      connection =
        start_connection(context,
          transport: {FakeTransport, [test_pid: self(), start_error: :enoent]}
        )

      assert_receive {:transport_start_attempted, :enoent}, 1_000
      assert_receive {:transport_start_attempted, :enoent}, 1_000
      assert_receive {:transport_start_attempted, :enoent}, 1_000

      assert Process.alive?(connection)
      assert entry_names(context.catalog) == []
    end

    test "a transport process that dies is handled like a closed one", context do
      start_connection(context)
      first = started_transport()
      FakeTransport.complete_handshake(first, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      Process.exit(first, :kill)

      wait_until(fn -> entry_names(context.catalog) == [] end)
      assert started_transport() != first
    end

    test "a failed send during the handshake disconnects and retries", context do
      start_connection(context)
      first = started_transport()
      initialize = FakeTransport.next_request(first)

      [{connection, _value}] = Registry.lookup(context.registry, :fake)
      send(connection, {:mcp_send_failed, first, initialize["id"], :closed})

      assert started_transport() != first
    end

    test "late messages from a transport that was replaced are ignored", context do
      start_connection(context)
      first = started_transport()
      FakeTransport.complete_handshake(first, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.close(first, :gone)
      second = started_transport()
      FakeTransport.complete_handshake(second, [raw_tool("b")])
      wait_until(fn -> entry_names(context.catalog) == ["b"] end)

      FakeTransport.close(first, :late_close)
      Process.sleep(50)

      assert entry_names(context.catalog) == ["b"]
    end
  end

  describe "while connected" do
    test "a tools list_changed notification refreshes the catalog", context do
      start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.deliver(
        transport,
        ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
      )

      list = FakeTransport.next_request(transport)
      assert list["method"] == "tools/list"
      FakeTransport.reply(transport, list, %{"tools" => [raw_tool("a"), raw_tool("c")]})

      wait_until(fn -> entry_names(context.catalog) == ["a", "c"] end)
    end

    test "tools stay published while a refresh is in flight", context do
      start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.deliver(
        transport,
        ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
      )

      _list = FakeTransport.next_request(transport)

      assert entry_names(context.catalog) == ["a"]
    end

    test "two list_changed notifications in a row cause one refresh", context do
      start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      notification = ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
      FakeTransport.deliver(transport, notification)
      FakeTransport.deliver(transport, notification)

      _first_refresh = FakeTransport.next_request(transport)
      assert_raise RuntimeError, fn -> FakeTransport.next_request(transport, 100) end
    end

    test "a refresh the server never answers drops the stale tools and reconnects", context do
      start_connection(context, handshake_timeout: @short_timeout)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.deliver(
        transport,
        ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
      )

      _unanswered = FakeTransport.next_request(transport)

      replacement = started_transport()

      assert replacement != transport
      assert entry_names(context.catalog) == []
    end

    test "an answered refresh is not mistaken for a stuck one", context do
      start_connection(context, handshake_timeout: @short_timeout)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      FakeTransport.deliver(
        transport,
        ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
      )

      list = FakeTransport.next_request(transport)
      FakeTransport.reply(transport, list, %{"tools" => [raw_tool("b")]})
      wait_until(fn -> entry_names(context.catalog) == ["b"] end)

      # Longer than the handshake timeout the refresh was started under.
      Process.sleep(@short_timeout + 100)

      assert entry_names(context.catalog) == ["b"]
      refute_received {:transport_started, _another}
    end

    test "answers a server ping with an empty result", context do
      start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [])

      FakeTransport.deliver(transport, ~s({"jsonrpc":"2.0","id":"p1","method":"ping"}))

      assert %{"id" => "p1", "result" => %{}} = FakeTransport.next_request(transport)
    end

    test "refuses any other server request with method not found", context do
      start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [])

      FakeTransport.deliver(
        transport,
        ~s({"jsonrpc":"2.0","id":4,"method":"sampling/createMessage"})
      )

      assert %{"id" => 4, "error" => %{"code" => -32_601}} = FakeTransport.next_request(transport)
    end

    test "garbage, unknown ids, and unknown notifications change nothing", context do
      connection = start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [raw_tool("a")])
      wait_until(fn -> entry_names(context.catalog) == ["a"] end)

      for junk <- [
            "",
            "not json",
            "[]",
            ~s({"jsonrpc":"2.0","id":999,"result":{}}),
            ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}})
          ] do
        FakeTransport.deliver(transport, junk)
      end

      Process.sleep(50)
      assert Process.alive?(connection)
      assert entry_names(context.catalog) == ["a"]
    end
  end

  describe "shutdown and crash reports" do
    test "terminating the connection stops its transport before returning", context do
      connection = start_connection(context)
      transport = started_transport()
      FakeTransport.complete_handshake(transport, [])
      wait_until(fn -> :sys.get_state(connection).phase == :ready end)

      monitor = Process.monitor(transport)
      Connection.terminate(:shutdown, :sys.get_state(connection))

      assert_received {:DOWN, ^monitor, :process, ^transport, _reason}
    end

    test "the state shown in crash reports never carries the configured headers", context do
      connection =
        start_connection(context,
          transport:
            {FakeTransport,
             [test_pid: self(), headers: [{"authorization", "Bearer SECRET-0123456789"}]]}
        )

      started_transport()

      status =
        connection |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

      refute status =~ "SECRET-0123456789"
    end
  end
end
