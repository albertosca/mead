defmodule Mead.Deck.PlugTest do
  # Changes the global :storage setting and talks to a real listener.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mead.Test.DeckServer

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous = Application.get_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mead, :storage)
        value -> Application.put_env(:mead, :storage, value)
      end
    end)

    %{server: DeckServer.start(directory), directory: directory}
  end

  defp url(server, path), do: "http://127.0.0.1:#{server.port}#{path}"

  defp raw_post(server, options),
    do: Req.post!(url(server, "/deck/ticket"), Keyword.merge([retry: false], options))

  describe "POST /deck/ticket authentication" do
    test "no authorization header is 401 with a challenge", %{server: server} do
      response = raw_post(server, [])
      assert response.status == 401
      assert response.body == %{"error" => "unauthorized"}
      assert Req.Response.get_header(response, "www-authenticate") == ["Bearer"]
    end

    test "a wrong token and a wrong scheme are 401", %{server: server} do
      assert DeckServer.request_ticket(server, nil, "wrong-token").status == 401

      assert raw_post(server, headers: [authorization: "Basic " <> server.token]).status == 401
      assert raw_post(server, headers: [authorization: server.token]).status == 401
    end

    test "the token is checked before the body is read", %{server: server} do
      response =
        raw_post(server, headers: [authorization: "Bearer nope"], body: "{this is not json")

      assert response.status == 401
    end

    test "the MCP token is not accepted", %{tmp_dir: directory} do
      server = DeckServer.start(directory, [], [], token: "the-mcp-token")
      assert DeckServer.request_ticket(server, nil, "the-mcp-token").status == 401
    end
  end

  describe "POST /deck/ticket body" do
    test "a body that is not a JSON object is 400", %{server: server} do
      for body <- ["[]", "\"x\"", "3", "{not json"] do
        response =
          raw_post(server,
            headers: [
              authorization: "Bearer " <> server.token,
              "content-type": "application/json"
            ],
            body: body,
            decode_body: false
          )

        assert response.status == 400, "body #{inspect(body)}"
      end
    end

    test "a session_id that is not a session identifier is 400", %{server: server} do
      for value <- ["not-a-uuid", "../../etc/passwd", 5, nil, ""] do
        assert DeckServer.request_ticket(server, %{"session_id" => value}).status == 400,
               inspect(value)
      end
    end

    test "any other field is 400", %{server: server} do
      assert DeckServer.request_ticket(server, %{"handler" => "x"}).status == 400
    end

    test "an unknown session id is 404", %{server: server} do
      response = DeckServer.request_ticket(server, %{"session_id" => Mead.UUID.generate()})
      assert response.status == 404
      assert response.body == %{"error" => "session not found"}
    end

    test "a body over the limit is 413", %{server: server} do
      response =
        raw_post(server,
          headers: [authorization: "Bearer " <> server.token, "content-type": "application/json"],
          body: JSON.encode!(%{"session_id" => String.duplicate("a", 5_000)})
        )

      assert response.status == 413
    end
  end

  describe "POST /deck/ticket sessions" do
    test "no body creates a running session and answers a ticket", %{server: server} do
      response = DeckServer.request_ticket(server)

      assert response.status == 200
      assert Req.Response.get_header(response, "cache-control") == ["no-store"]

      assert %{"ticket" => ticket, "session_id" => session_id, "expires_in_ms" => 10_000} =
               response.body

      assert is_binary(ticket) and byte_size(ticket) > 16
      assert Mead.Session.Store.valid_session_id?(session_id)
      assert Mead.Session.whereis(session_id, :supervisor)
    end

    test "an empty object also creates a session", %{server: server} do
      assert %Req.Response{status: 200} = DeckServer.request_ticket(server, %{})
    end

    test "every ticket is different and the session is not reused without an id", %{
      server: server
    } do
      first = DeckServer.ticket(server)
      second = DeckServer.ticket(server)

      refute first["ticket"] == second["ticket"]
      refute first["session_id"] == second["session_id"]
    end

    test "a running session id is reused", %{server: server} do
      %{"session_id" => session_id} = DeckServer.ticket(server)
      again = DeckServer.ticket(server, session_id)

      assert again["session_id"] == session_id
    end

    test "a stopped session with a stored history is resumed with it", %{server: server} do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 5_000)

      {:ok, "remembered"} = Mead.submit_turn(session_id, "echo remembered")
      :ok = Mead.stop_session(session_id)
      refute Mead.Session.whereis(session_id, :supervisor)

      assert %{"session_id" => ^session_id} = DeckServer.ticket(server, session_id)
      assert Mead.Session.whereis(session_id, :supervisor)
      assert {:ok, [turn]} = Mead.history(session_id)
      assert inspect(turn) =~ "remembered"
    end

    test "a ticket expires after ticket_ttl_ms", %{tmp_dir: directory} do
      server = DeckServer.start(directory, ticket_ttl_ms: 50)
      %{"ticket" => ticket} = DeckServer.ticket(server)
      Process.sleep(120)

      assert {:error, 401, _body} =
               Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)
    end
  end

  describe "GET /deck/socket" do
    test "without a ticket, with an empty one and with an unknown one is 401", %{server: server} do
      for query <- ["", "?ticket=", "?ticket=unknown", "?ticket[]=a", "?other=1"] do
        assert {:error, 401, _body} =
                 Mead.Test.WebSocketClient.connect(server.port, "/deck/socket" <> query),
               query
      end
    end

    test "a plain GET with a valid ticket is 426 and does not burn the ticket", %{
      server: server
    } do
      %{"ticket" => ticket} = DeckServer.ticket(server)
      response = Req.get!(url(server, "/deck/socket?ticket=" <> ticket), retry: false)
      assert response.status == 426

      assert {:ok, client} =
               Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)

      Mead.Test.WebSocketClient.close(client)
    end

    test "a ticket works once", %{server: server} do
      %{"ticket" => ticket} = DeckServer.ticket(server)

      assert {:ok, client} =
               Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)

      Mead.Test.WebSocketClient.close(client)

      assert {:error, 401, _body} =
               Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)
    end
  end

  describe "routing" do
    test "the wrong method is 405 with allow", %{server: server} do
      for method <- [:get, :put, :delete, :options, :patch] do
        response = Req.request!(url: url(server, "/deck/ticket"), method: method, retry: false)
        assert response.status == 405, "#{method}"
        assert Req.Response.get_header(response, "allow") == ["POST"]
      end

      for method <- [:post, :put, :options] do
        response = Req.request!(url: url(server, "/deck/socket"), method: method, retry: false)
        assert response.status == 405, "#{method}"
        assert Req.Response.get_header(response, "allow") == ["GET"]
      end
    end

    test "any other path under /deck is 404", %{server: server} do
      for path <- ["/deck", "/deck/", "/deck/other", "/deck/ticket/extra"] do
        assert Req.get!(url(server, path), retry: false).status == 404, path
      end
    end

    test "/mcp is not served when only the deck is configured", %{server: server} do
      assert Req.post!(url(server, "/mcp"), json: %{}, retry: false).status == 404
    end
  end

  describe "the Origin rule" do
    test "a foreign origin is 403 on the ticket and on the socket", %{server: server} do
      assert raw_post(server,
               headers: [authorization: "Bearer " <> server.token, origin: "https://evil.example"]
             ).status == 403

      %{"ticket" => ticket} = DeckServer.ticket(server)

      assert {:error, 403, _body} =
               Mead.Test.WebSocketClient.connect(
                 server.port,
                 "/deck/socket?ticket=" <> ticket,
                 [{"origin", "https://evil.example"}]
               )

      # The refusal came before the ticket was consumed, so the owner can still use it.
      assert {:ok, client} =
               Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)

      Mead.Test.WebSocketClient.close(client)
    end

    test "loopback and listed origins pass", %{tmp_dir: directory} do
      server =
        DeckServer.start(directory, [], [], allowed_origins: ["https://deck.example"])

      for origin <- ["http://localhost:5173", "https://deck.example"] do
        response =
          raw_post(server,
            headers: [authorization: "Bearer " <> server.token, origin: origin]
          )

        assert response.status == 200, origin
      end
    end
  end

  describe "logs" do
    test "no request leaks the token, the ticket or the body", %{server: server} do
      %{"ticket" => ticket} = DeckServer.ticket(server)

      log =
        capture_log(fn ->
          DeckServer.request_ticket(server, nil, "leaky-wrong-token")

          raw_post(server,
            headers: [authorization: "Bearer " <> server.token],
            body: "{secret-body"
          )

          Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=leaky-ticket")

          {:ok, client} =
            Mead.Test.WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)

          Mead.Test.WebSocketClient.close(client)
          Process.sleep(50)
        end)

      for secret <- ["leaky-wrong-token", server.token, "leaky-ticket", ticket, "secret-body"] do
        refute log =~ secret, "the log contains #{secret}"
      end
    end
  end
end
