defmodule Mead.OriginTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]

  defp request(origins) do
    Enum.reduce(origins, conn(:get, "/"), &Plug.Conn.prepend_req_headers(&2, [{"origin", &1}]))
  end

  test "a request without an Origin passes" do
    assert Mead.Origin.check(conn(:get, "/"), []) == :ok
  end

  test "loopback origins pass on any port and scheme http or https" do
    for origin <- ["http://localhost:3000", "https://127.0.0.1", "http://[::1]:8080"] do
      assert Mead.Origin.check(request([origin]), []) == :ok, origin
    end
  end

  test "a listed origin passes and an unlisted one does not" do
    assert Mead.Origin.check(request(["https://deck.example"]), ["https://deck.example"]) == :ok
    assert Mead.Origin.check(request(["https://deck.example"]), []) == :forbidden

    assert Mead.Origin.check(request(["https://evil.example"]), ["https://deck.example"]) ==
             :forbidden
  end

  test "lookalikes, credentials and several values are refused" do
    for origin <- [
          "http://localhost.evil.example",
          "http://user@localhost",
          "ftp://localhost",
          "null"
        ] do
      assert Mead.Origin.check(request([origin]), []) == :forbidden, origin
    end

    assert Mead.Origin.check(request(["http://localhost", "http://localhost"]), []) == :forbidden
  end
end
