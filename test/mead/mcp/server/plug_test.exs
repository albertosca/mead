defmodule Mead.MCP.Server.PlugTest.RaisingDispatcher do
  @moduledoc false

  def dispatch(_message, _context), do: raise("boom with a secret detail")
end

defmodule Mead.MCP.Server.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.MCP.Server.Configuration
  alias Mead.MCP.Server.Plug, as: ServerPlug

  @token "plug-test-token-0123456789"
  @ping JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
  @maximum_body 1_048_576
  @good_headers [{"authorization", "Bearer " <> @token}, {"content-type", "application/json"}]

  defp configuration(settings) do
    {:ok, configuration} = Configuration.load([token: @token] ++ settings)
    configuration
  end

  defp run(conn, extra_options \\ [], settings \\ []) do
    options = ServerPlug.init([configuration: configuration(settings)] ++ extra_options)
    ServerPlug.call(conn, options)
  end

  defp post(body, headers \\ @good_headers, path \\ "/mcp") do
    Enum.reduce(headers, Plug.Test.conn(:post, path, body), fn {name, value}, conn ->
      %{conn | req_headers: conn.req_headers ++ [{name, value}]}
    end)
  end

  defp json_body(conn), do: JSON.decode!(conn.resp_body)

  test "a valid request is dispatched and answered with one JSON object" do
    conn = @ping |> post() |> run()

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}} = json_body(conn)
  end

  test "a notification is accepted with an empty body" do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    conn = body |> post() |> run()

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "the content type may carry parameters" do
    headers = [
      {"authorization", "Bearer " <> @token},
      {"content-type", "application/json; charset=utf-8"}
    ]

    assert (@ping |> post(headers) |> run()).status == 200
  end

  describe "routing" do
    test "GET /mcp is 405 and says POST is allowed" do
      conn = :get |> Plug.Test.conn("/mcp") |> run()

      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
    end

    test "other methods on /mcp are 405 too" do
      for method <- [:put, :delete, :patch] do
        assert (method |> Plug.Test.conn("/mcp") |> run()).status == 405
      end
    end

    test "any other path is 404, with or without the token" do
      for path <- ["/", "/mcp/extra", "/other"] do
        assert (@ping |> post(@good_headers, path) |> run()).status == 404
        assert (@ping |> post([], path) |> run()).status == 404
      end
    end
  end

  describe "the bearer token" do
    test "missing, wrong, and same-length-wrong tokens are 401 with a challenge" do
      same_length = String.duplicate("x", byte_size(@token))
      json = {"content-type", "application/json"}

      for headers <- [
            [json],
            [{"authorization", "Bearer wrong"}, json],
            [{"authorization", "Bearer " <> same_length}, json],
            [{"authorization", "Bearer "}, json],
            [{"authorization", "Basic " <> @token}, json],
            [{"authorization", @token}, json]
          ] do
        conn = @ping |> post(headers) |> run()

        assert conn.status == 401
        assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end
    end

    test "two authorization headers are refused" do
      headers = [
        {"authorization", "Bearer " <> @token},
        {"authorization", "Bearer " <> @token},
        {"content-type", "application/json"}
      ]

      assert (@ping |> post(headers) |> run()).status == 401
    end

    test "the scheme is case-insensitive" do
      headers = [{"authorization", "bearer " <> @token}, {"content-type", "application/json"}]

      assert (@ping |> post(headers) |> run()).status == 200
    end

    test "is checked before the body is looked at, even an oversized or malformed one" do
      oversized = String.duplicate("x", @maximum_body + 1)
      headers = [{"authorization", "Bearer wrong"}, {"content-type", "application/json"}]

      assert (oversized |> post(headers) |> run()).status == 401
      assert ("not json" |> post(headers) |> run()).status == 401
    end

    test "no refusal puts the token in the body or in a header" do
      refusals = [
        post(@ping, [{"authorization", "Bearer " <> @token <> "x"}]),
        post(@ping, @good_headers ++ [{"origin", "https://evil.example"}]),
        post(@ping, [{"authorization", "Bearer " <> @token}, {"content-type", "text/plain"}]),
        post("{broken"),
        post(@ping, @good_headers, "/nope")
      ]

      for conn <- refusals do
        conn = run(conn)

        refute conn.resp_body =~ @token
        refute inspect(conn.resp_headers) =~ @token
      end
    end
  end

  describe "the Origin header" do
    defp with_origin(origin), do: @good_headers ++ [{"origin", origin}]

    test "is optional, and loopback origins pass" do
      assert (@ping |> post() |> run()).status == 200

      for origin <- [
            "http://localhost",
            "http://localhost:3000",
            "http://127.0.0.1:8080",
            "https://localhost",
            "http://[::1]:3000"
          ] do
        assert (@ping |> post(with_origin(origin)) |> run()).status == 200,
               "expected #{origin} to pass"
      end
    end

    test "a foreign origin is 403" do
      for origin <- [
            "https://evil.example",
            "null",
            "http://localhost.evil.example",
            "http://127.0.0.1.evil.example",
            "http://localhost@evil.example",
            "ftp://localhost",
            ""
          ] do
        assert (@ping |> post(with_origin(origin)) |> run()).status == 403,
               "expected #{inspect(origin)} to be refused"
      end
    end

    test "an origin listed in allowed_origins passes, by exact match only" do
      settings = [allowed_origins: ["https://deck.example"]]

      for {origin, status} <- [
            {"https://deck.example", 200},
            {"https://deck.example.evil", 403},
            {"http://deck.example", 403}
          ] do
        assert (@ping |> post(with_origin(origin)) |> run([], settings)).status == status,
               "expected #{origin} to answer #{status}"
      end
    end

    test "two origin headers are refused" do
      headers = @good_headers ++ [{"origin", "http://localhost"}, {"origin", "http://localhost"}]

      assert (@ping |> post(headers) |> run()).status == 403
    end

    test "the token is checked first: a bad token with a bad origin is 401" do
      headers = [
        {"authorization", "Bearer wrong"},
        {"content-type", "application/json"},
        {"origin", "https://evil.example"}
      ]

      assert (@ping |> post(headers) |> run()).status == 401
    end
  end

  describe "the content type" do
    test "is checked after the token and the origin: a bad token with a bad type is 401" do
      wrong_token = [{"authorization", "Bearer wrong"}, {"content-type", "text/plain"}]
      assert (@ping |> post(wrong_token) |> run()).status == 401

      foreign_origin = [
        {"authorization", "Bearer " <> @token},
        {"content-type", "text/plain"},
        {"origin", "https://evil.example"}
      ]

      assert (@ping |> post(foreign_origin) |> run()).status == 403
    end

    test "anything but JSON is 415" do
      auth = {"authorization", "Bearer " <> @token}

      for headers <- [
            [auth],
            [auth, {"content-type", "text/plain"}],
            [auth, {"content-type", "application/x-www-form-urlencoded"}],
            [auth, {"content-type", "garbage"}]
          ] do
        assert (@ping |> post(headers) |> run()).status == 415
      end
    end
  end

  describe "the body" do
    defp ping_of_size(size) do
      envelope = fn padding ->
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping",
          "params" => %{"pad" => padding}
        })
      end

      envelope.(String.duplicate("a", size - byte_size(envelope.(""))))
    end

    test "exactly 1 MiB is accepted and one byte more is 413" do
      exact = ping_of_size(@maximum_body)
      assert byte_size(exact) == @maximum_body
      assert (exact |> post() |> run()).status == 200

      over = ping_of_size(@maximum_body + 1)
      assert byte_size(over) == @maximum_body + 1
      assert (over |> post() |> run()).status == 413
    end

    test "text that is not JSON is a 400 parse error" do
      for body <- ["", "not json", "{\"jsonrpc\":"] do
        conn = body |> post() |> run()

        assert conn.status == 400
        assert json_body(conn)["error"]["code"] == -32_700
        assert json_body(conn)["id"] == nil
      end
    end

    test "JSON that is not a request is a 400 invalid request, a batch included" do
      for body <- [
            "[]",
            "[#{@ping}]",
            "[#{@ping},#{@ping}]",
            "42",
            "null",
            "\"text\"",
            "{}",
            ~s({"jsonrpc":"1.0","id":1,"method":"ping"}),
            ~s({"jsonrpc":"2.0","id":null,"method":"ping"}),
            ~s({"jsonrpc":"2.0","id":1.5,"method":"ping"}),
            ~s({"jsonrpc":"2.0","id":1})
          ] do
        conn = body |> post() |> run()

        assert conn.status == 400, "expected 400 for #{body}"
        assert json_body(conn)["error"]["code"] == -32_600
      end
    end

    test "deeply nested JSON does not crash the request" do
      deep = String.duplicate("[", 100_000) <> String.duplicate("]", 100_000)

      assert (deep |> post() |> run()).status == 400
    end
  end

  describe "a bug inside the dispatcher" do
    test "is a generic 500 and the log names only the exception module, never the token" do
      log =
        capture_log(fn ->
          conn = @ping |> post() |> run(dispatcher: Mead.MCP.Server.PlugTest.RaisingDispatcher)

          assert conn.status == 500
          assert json_body(conn)["error"]["code"] == -32_603
          refute conn.resp_body =~ "boom"
          refute conn.resp_body =~ "secret detail"
        end)

      assert log =~ "RuntimeError"
      refute log =~ @token
      refute log =~ "boom"
    end
  end
end
