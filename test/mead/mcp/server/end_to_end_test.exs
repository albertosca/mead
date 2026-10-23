defmodule Mead.MCP.Server.EndToEndTest do
  # A real listener on a real socket, driven by the project's own HTTP client transport through a
  # real connection. This is also the first time `Mead.MCP.Transport.Http` talks to a real server.
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.{Catalog, Connection, Server}

  @moduletag :capture_log
  @token "end-to-end-token-0123456789"

  setup do
    suffix = System.unique_integer([:positive])
    server = :"end_to_end_server_#{suffix}"
    registry = :"end_to_end_registry_#{suffix}"
    catalog = :"end_to_end_catalog_#{suffix}"

    start_supervised!({Server, name: server, settings: [token: @token, port: 0]})
    {:ok, port} = Server.port(server)
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Catalog, name: catalog, servers: []})

    start_supervised!(
      {Connection,
       server: :mead,
       registry: registry,
       catalog: catalog,
       transport:
         {Mead.MCP.Transport.Http,
          [
            url: "http://127.0.0.1:#{port}/mcp",
            headers: [{"authorization", "Bearer " <> @token}]
          ]},
       reconnect_delays: [100],
       handshake_timeout: 2_000}
    )

    wait_until(fn -> match?({:ok, [_ | _], _servers}, Catalog.snapshot(catalog)) end, 5_000)

    %{registry: registry, catalog: catalog, port: port}
  end

  defp call(context, name, arguments) do
    Connection.call_tool(context.registry, :mead, name, arguments, 5_000)
  end

  defp raw_post(port, body, headers) do
    Req.post!("http://127.0.0.1:#{port}/mcp",
      body: body,
      headers: headers,
      retry: false,
      decode_body: false
    )
  end

  @ping JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
  @json {"content-type", "application/json"}

  test "the handshake publishes the four tools", context do
    assert {:ok, tools, _servers} = Catalog.snapshot(context.catalog)
    assert length(tools) == 4
  end

  test "a full cycle: start, submit, read the history, stop", context do
    assert {:ok, %{content: session_id, is_error: false}} = call(context, "start_session", %{})
    on_exit(fn -> Mead.stop_session(session_id) end)

    assert {:ok, %{content: "hello", is_error: false}} =
             call(context, "submit_turn", %{"session_id" => session_id, "input" => "hello"})

    assert {:ok, %{content: history, is_error: false}} =
             call(context, "history", %{"session_id" => session_id})

    assert [%{"input" => "hello", "output" => "hello", "status" => "ok"}] =
             JSON.decode!(history)

    assert {:ok, %{content: "stopped", is_error: false}} =
             call(context, "stop_session", %{"session_id" => session_id})

    assert {:ok, %{content: "unknown session", is_error: true}} =
             call(context, "submit_turn", %{"session_id" => session_id, "input" => "again"})
  end

  test "a tool failure does not break the connection", context do
    assert {:ok, %{is_error: true}} = call(context, "history", %{"session_id" => "nope"})
    assert {:ok, %{is_error: false}} = call(context, "start_session", %{})
  end

  test "invalid params come back as an rpc error", context do
    assert {:error, {:rpc_error, -32_602, message}} =
             call(context, "history", %{"session_id" => 5})

    assert message == "session_id must be a string"
  end

  describe "over a raw socket" do
    test "a request without the token, or with a wrong one, never reaches a session", context do
      assert raw_post(context.port, @ping, [@json]).status == 401

      assert raw_post(context.port, @ping, [@json, {"authorization", "Bearer wrong"}]).status ==
               401
    end

    test "a foreign origin is refused even with the right token", context do
      headers = [
        @json,
        {"authorization", "Bearer " <> @token},
        {"origin", "https://evil.example"}
      ]

      assert raw_post(context.port, @ping, headers).status == 403
    end

    test "a GET is 405", context do
      response =
        Req.get!("http://127.0.0.1:#{context.port}/mcp",
          headers: [{"authorization", "Bearer " <> @token}],
          retry: false
        )

      assert response.status == 405
      assert Req.Response.get_header(response, "allow") == ["POST"]
    end

    test "a body over 1 MiB is 413", context do
      body = String.duplicate("x", 1024 * 1024 + 1)
      headers = [@json, {"authorization", "Bearer " <> @token}]

      assert raw_post(context.port, body, headers).status == 413
    end

    test "a batch is refused and a notification is accepted", context do
      headers = [@json, {"authorization", "Bearer " <> @token}]

      assert raw_post(context.port, "[#{@ping}]", headers).status == 400

      notification = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert raw_post(context.port, notification, headers).status == 202
    end
  end
end
