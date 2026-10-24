defmodule Mead.MCP.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mead.TestHelpers

  alias Mead.MCP.Server

  @token "server-test-token-0123456789"

  defp unique_name, do: :"mcp_server_#{System.unique_integer([:positive])}"

  defp post_ping(port, headers) do
    Req.post!("http://127.0.0.1:#{port}/mcp",
      body: JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}),
      headers: [{"content-type", "application/json"} | headers],
      retry: false,
      decode_body: false
    )
  end

  defp served?(port) do
    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false]) do
      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      :ok =
        :gen_tcp.send(
          socket,
          "POST /mcp HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer #{@token}\r\n" <>
            "content-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
            body
        )

      match?({:ok, "HTTP/1.1 200" <> _rest}, :gen_tcp.recv(socket, 0, 5_000))
    else
      _refused -> false
    end
  end

  test "without a token it starts nothing, says so once, and has no port" do
    name = unique_name()

    log = capture_log(fn -> start_supervised!({Server, name: name, settings: []}) end)

    assert Supervisor.which_children(name) == []
    assert Server.port(name) == :error
    assert log =~ "MCP server is disabled"
  end

  test "with a token it listens on the requested port, loopback by default" do
    name = unique_name()
    start_supervised!({Server, name: name, settings: [token: @token, port: 0]})

    assert {:ok, port} = Server.port(name)
    assert port > 0

    [{_id, listener, :supervisor, _modules}] = Supervisor.which_children(name)
    assert {:ok, {{127, 0, 0, 1}, ^port}} = ThousandIsland.listener_info(listener)
  end

  test "the listener refuses a request without the token and serves one with it" do
    name = unique_name()
    start_supervised!({Server, name: name, settings: [token: @token, port: 0]})
    {:ok, port} = Server.port(name)

    assert post_ping(port, []).status == 401
    assert post_ping(port, [{"authorization", "Bearer wrong"}]).status == 401
    assert post_ping(port, [{"authorization", "Bearer " <> @token}]).status == 200
  end

  test "allow_effect and allowed_origins reach the plug" do
    name = unique_name()

    start_supervised!(
      {Server,
       name: name, settings: [token: @token, port: 0, allowed_origins: ["https://deck.example"]]}
    )

    {:ok, port} = Server.port(name)
    headers = [{"authorization", "Bearer " <> @token}]

    assert post_ping(port, [{"origin", "https://deck.example"} | headers]).status == 200
    assert post_ping(port, [{"origin", "https://evil.example"} | headers]).status == 403
  end

  test "an invalid configuration stops the start with a message that never contains the token" do
    Process.flag(:trap_exit, true)

    for settings <- [
          [token: @token, port: 70_000],
          [token: @token, address: "localhost"],
          [token: 42]
        ] do
      log =
        capture_log(fn ->
          result = Server.start_link(name: unique_name(), settings: settings)

          assert {:error, _reason} = result
          refute inspect(result, limit: :infinity) =~ @token
        end)

      refute log =~ @token
    end
  end

  test "the message names the setting that is wrong" do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert {:error, reason} =
               Server.start_link(name: unique_name(), settings: [token: @token, port: 70_000])

      assert inspect(reason) =~ "port must be an integer from 0 to 65535"
    end)
  end

  test "a listener that dies is started again, on a working port" do
    name = unique_name()
    start_supervised!({Server, name: name, settings: [token: @token, port: 0]})
    [{_id, listener, :supervisor, _modules}] = Supervisor.which_children(name)

    Process.exit(listener, :kill)

    assert {:ok, port} =
             wait_until(fn ->
               match?({:ok, _port}, Server.port(name)) and Server.port(name)
             end)

    assert post_ping(port, [{"authorization", "Bearer " <> @token}]).status == 200
  end

  test "a connection beyond maximum_connections is closed, and one is served again once room is free" do
    name = unique_name()

    start_supervised!(
      {Server, name: name, settings: [token: @token, port: 0, maximum_connections: 1]}
    )

    {:ok, port} = Server.port(name)
    options = [:binary, active: false]
    {:ok, holder} = :gen_tcp.connect({127, 0, 0, 1}, port, options)
    on_exit(fn -> :gen_tcp.close(holder) end)
    {:ok, refused} = :gen_tcp.connect({127, 0, 0, 1}, port, options)

    # The one allowed connection stays open, so there is never room for the second.
    assert {:error, :closed} = :gen_tcp.recv(refused, 0, 10_000)

    :gen_tcp.close(holder)

    assert wait_until(fn -> served?(port) end)
  end

  test "port/1 of a server that is not running is :error, not a crash" do
    assert Server.port(:no_such_mcp_server) == :error
  end
end
