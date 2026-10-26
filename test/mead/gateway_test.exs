defmodule Mead.GatewayTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Mead.Gateway

  defmodule Stub do
    @behaviour Plug
    @impl Plug
    def init(label), do: label
    @impl Plug
    def call(conn, label), do: send_resp(conn, 200, to_string(label))
  end

  defp request(options, path) do
    gateway = Gateway.init(options)
    conn = %{Plug.Test.conn(:get, path) | path_info: path_segments(path)}
    Gateway.call(conn, gateway)
  end

  defp path_segments(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))

  defp both, do: [mcp: {Stub, :mcp}, deck: {Stub, :deck}]

  test "/mcp goes to the MCP plug and /deck paths to the deck plug" do
    assert request(both(), "/mcp").resp_body == "mcp"
    assert request(both(), "/deck/ticket").resp_body == "deck"
    assert request(both(), "/deck/socket").resp_body == "deck"
    assert request(both(), "/deck").resp_body == "deck"
  end

  test "any other path goes to the MCP plug when it is present, so its 404 stays its own" do
    assert request(both(), "/other").resp_body == "mcp"
    assert request([mcp: {Stub, :mcp}, deck: nil], "/deck/ticket").resp_body == "mcp"
  end

  test "without an MCP plug an unknown path is an empty 404" do
    conn = request([mcp: nil, deck: {Stub, :deck}], "/other")
    assert conn.status == 404
    assert conn.resp_body == ""

    assert request([mcp: nil, deck: {Stub, :deck}], "/mcp").status == 404
  end

  test "without a deck plug /deck/ticket is an empty 404 when nothing else answers" do
    conn = request([mcp: nil, deck: nil], "/deck/ticket")
    assert conn.status == 404
    assert conn.resp_body == ""
  end

  test "only the first path segment selects a plug" do
    for path <- ["/x/deck", "/../deck", "/x/mcp", "/mcp/../deck"] do
      conn = request([mcp: nil, deck: {Stub, :deck}], path)
      assert conn.status == 404 or conn.resp_body != "deck", "#{path} reached the deck"
    end

    assert request([mcp: nil, deck: {Stub, :deck}], "/x/deck").status == 404
    assert request([mcp: {Stub, :mcp}, deck: {Stub, :deck}], "/mcp/../deck").resp_body == "mcp"
    assert request([mcp: {Stub, :mcp}, deck: {Stub, :deck}], "/x/deck").resp_body == "mcp"
  end

  test "a plug's init runs once, at gateway init" do
    defmodule Counting do
      @behaviour Plug
      @impl Plug
      def init(parent) do
        send(parent, :initialised)
        :state
      end

      @impl Plug
      def call(conn, :state), do: send_resp(conn, 200, "ok")
    end

    gateway = Gateway.init(mcp: {Counting, self()}, deck: nil)
    assert_received :initialised
    Gateway.call(Plug.Test.conn(:get, "/mcp"), gateway)
    Gateway.call(Plug.Test.conn(:get, "/mcp"), gateway)
    refute_received :initialised
  end
end
