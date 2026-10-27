defmodule Mead.Deck.EventStreamTest do
  # Talks to a real listener and changes the global :storage setting.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.SseClient

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

    %{directory: directory}
  end

  defp start_server(directory, deck_settings \\ []),
    do: DeckServer.start(directory, deck_settings)

  # Opens the stream for a fresh (or given) session and reads its first event.
  defp open_stream(server, session_id \\ nil, query \\ "", headers \\ []) do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server, session_id)
    on_exit(fn -> Mead.stop_session(session_id) end)

    {:ok, client} =
      SseClient.connect(server.port, "/deck/events?ticket=" <> ticket <> query, headers)

    {client, connected} = SseClient.receive_json(client)
    {client, session_id, connected}
  end

  defp post_message(server, token, message, extra_headers \\ []) do
    Req.post!("http://127.0.0.1:#{server.port}/deck/messages",
      json: message,
      headers: [{"authorization", "Bearer " <> token}] ++ extra_headers,
      retry: false
    )
  end

  defp prompt(text),
    do: %{
      "type" => "prompt.send",
      "payload" => %{
        "client_message_id" => "m-#{System.unique_integer([:positive])}",
        "text" => text
      }
    }

  defp connection_token(%{data: %{"connection_token" => token}}), do: token

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk("the condition never became true")

      true ->
        Process.sleep(20)
        wait_until(check, attempts - 1)
    end
  end

  describe "GET /deck/events" do
    test "streams as text/event-stream and opens with the connection token", %{
      directory: directory
    } do
      server = start_server(directory)
      %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
      on_exit(fn -> Mead.stop_session(session_id) end)

      {:ok, client} = SseClient.connect(server.port, "/deck/events?ticket=" <> ticket)
      assert client.status == 200
      assert SseClient.header(client, "content-type") =~ "text/event-stream"
      assert SseClient.header(client, "cache-control") == "no-store"
      assert SseClient.header(client, "connection") == "close"

      {client, connected} = SseClient.receive_json(client)
      assert connected.event == "connected"
      assert connected.id == nil
      assert %{"connection_token" => token, "session_id" => ^session_id} = connected.data
      assert is_binary(token) and byte_size(token) >= 20

      {_client, snapshot} = SseClient.receive_type(client, "session.snapshot")
      assert snapshot.id == nil
      assert snapshot.data["payload"]["protocol_version"] == 1
    end

    test "a ticket opens one stream only", %{directory: directory} do
      server = start_server(directory)
      %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
      on_exit(fn -> Mead.stop_session(session_id) end)

      assert {:ok, %{status: 200}} =
               SseClient.connect(server.port, "/deck/events?ticket=" <> ticket)

      assert {:ok, %{status: 401}} =
               SseClient.connect(server.port, "/deck/events?ticket=" <> ticket)
    end

    test "no ticket and a wrong ticket are 401", %{directory: directory} do
      server = start_server(directory)
      assert {:ok, %{status: 401}} = SseClient.connect(server.port, "/deck/events")
      assert {:ok, %{status: 401}} = SseClient.connect(server.port, "/deck/events?ticket=nope")
    end

    test "a foreign Origin is 403 before the ticket is redeemed", %{directory: directory} do
      server = start_server(directory)
      %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
      on_exit(fn -> Mead.stop_session(session_id) end)

      path = "/deck/events?ticket=" <> ticket

      assert {:ok, %{status: 403}} =
               SseClient.connect(server.port, path, [{"origin", "https://evil.example"}])

      assert {:ok, %{status: 200}} = SseClient.connect(server.port, path)
    end

    test "a malformed resume position is 400 and does not burn the ticket", %{
      directory: directory
    } do
      server = start_server(directory)
      %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
      on_exit(fn -> Mead.stop_session(session_id) end)

      base = "/deck/events?ticket=" <> ticket

      for bad <- [
            "&last_sequence=-1",
            "&last_sequence=abc",
            "&last_sequence=1.5",
            "&last_sequence="
          ] do
        assert {:ok, %{status: 400}} = SseClient.connect(server.port, base <> bad)
      end

      assert {:ok, %{status: 400}} =
               SseClient.connect(server.port, base, [{"last-event-id", "nope"}])

      assert {:ok, %{status: 400}} =
               SseClient.connect(server.port, base <> "&device_id=" <> String.duplicate("a", 129))

      assert {:ok, %{status: 200}} = SseClient.connect(server.port, base)
    end

    test "a method other than GET is 405", %{directory: directory} do
      server = start_server(directory)
      response = Req.post!("http://127.0.0.1:#{server.port}/deck/events", retry: false)
      assert response.status == 405
      assert Req.Response.get_header(response, "allow") == ["GET"]
    end
  end

  describe "POST /deck/messages" do
    test "a client message with the connection token reaches the session", %{directory: directory} do
      server = start_server(directory)
      {client, _session_id, connected} = open_stream(server)

      response = post_message(server, connection_token(connected), prompt("echo hello"))
      assert response.status == 202

      {client, accepted} = SseClient.receive_type(client, "prompt.accepted")
      assert accepted.id == Integer.to_string(accepted.data["sequence"])

      {_client, delta} = SseClient.receive_type(client, "text.delta")
      assert delta.data["payload"]["text"] == "hello"
    end

    test "no token, a wrong token and a token of a closed stream are 401", %{directory: directory} do
      server = start_server(directory)
      {client, _session_id, connected} = open_stream(server)
      token = connection_token(connected)

      assert Req.post!("http://127.0.0.1:#{server.port}/deck/messages",
               json: prompt("x"),
               retry: false
             ).status == 401

      assert post_message(server, "wrong-token", prompt("echo x")).status == 401

      SseClient.close(client)

      wait_until(fn -> post_message(server, token, prompt("echo x")).status == 401 end)
    end

    test "the ticket and the deck token cannot authorise a message", %{directory: directory} do
      server = start_server(directory)
      assert post_message(server, server.token, prompt("echo x")).status == 401
    end

    test "an invalid message is 400 with the reason, and nothing reaches the session", %{
      directory: directory
    } do
      server = start_server(directory)
      {client, _session_id, connected} = open_stream(server)
      token = connection_token(connected)

      for {message, reason} <- [
            {%{"type" => "prompt.send", "payload" => %{}}, "invalid_payload"},
            {%{"type" => "nope", "payload" => %{}}, "unknown_type"},
            {[1, 2], "not_object"}
          ] do
        response = post_message(server, token, message)
        assert response.status == 400
        assert response.body == %{"error" => reason}
      end

      {client, _snapshot} = SseClient.receive_type(client, "session.snapshot")
      assert {_client, :timeout} = SseClient.receive_json(client, 300)
    end

    test "a body that is not JSON is 400 and one over 64 KiB is 413", %{directory: directory} do
      server = start_server(directory)
      {_client, _session_id, connected} = open_stream(server)
      token = connection_token(connected)
      url = "http://127.0.0.1:#{server.port}/deck/messages"
      headers = [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}]

      assert Req.post!(url, body: "{not json", headers: headers, retry: false).status == 400

      big =
        JSON.encode!(%{
          "type" => "prompt.send",
          "payload" => %{"text" => String.duplicate("a", 70_000)}
        })

      assert Req.post!(url, body: big, headers: headers, retry: false).status == 413
    end

    test "session.resume is refused: the position is chosen when the stream opens", %{
      directory: directory
    } do
      server = start_server(directory)
      {_client, _session_id, connected} = open_stream(server)

      response =
        post_message(server, connection_token(connected), %{
          "type" => "session.resume",
          "payload" => %{"last_sequence" => 0}
        })

      assert response.status == 400
      assert response.body == %{"error" => "resume_not_accepted"}
    end

    test "a foreign Origin is 403", %{directory: directory} do
      server = start_server(directory)
      {_client, _session_id, connected} = open_stream(server)

      response =
        post_message(server, connection_token(connected), prompt("echo x"), [
          {"origin", "https://evil.example"}
        ])

      assert response.status == 403
    end

    test "a method other than POST is 405", %{directory: directory} do
      server = start_server(directory)
      response = Req.get!("http://127.0.0.1:#{server.port}/deck/messages", retry: false)
      assert response.status == 405
      assert Req.Response.get_header(response, "allow") == ["POST"]
    end

    test "two streams on one session both see its events and have their own tokens", %{
      directory: directory
    } do
      server = start_server(directory)
      {first, session_id, first_connected} = open_stream(server)
      {second, _session_id, second_connected} = open_stream(server, session_id)

      # Both streams see the shared session events.
      assert 202 ==
               post_message(server, connection_token(first_connected), prompt("echo one")).status

      {_first, _delta} = SseClient.receive_type(first, "text.delta")
      {_second, delta} = SseClient.receive_type(second, "text.delta")
      assert delta.data["payload"]["text"] == "one"

      assert connection_token(first_connected) != connection_token(second_connected)
    end
  end

  describe "resuming" do
    test "last_sequence replays only what the stream missed", %{directory: directory} do
      server = start_server(directory)
      {client, session_id, connected} = open_stream(server)
      post_message(server, connection_token(connected), prompt("echo hello"))
      {client, delta} = SseClient.receive_type(client, "text.delta")
      {_client, _metric} = SseClient.receive_type(client, "metric.updated")
      last = delta.data["sequence"]
      SseClient.close(client)

      {fresh, ^session_id, _connected} = open_stream(server, session_id, "&last_sequence=#{last}")
      {fresh, snapshot} = SseClient.receive_type(fresh, "session.snapshot")
      assert snapshot.data["payload"]["current_sequence"] >= last

      {_fresh, replayed} = SseClient.receive_json(fresh)
      assert replayed.data["sequence"] > last
    end

    test "the Last-Event-ID header works when the query has no position", %{directory: directory} do
      server = start_server(directory)
      {client, session_id, connected} = open_stream(server)
      post_message(server, connection_token(connected), prompt("echo hello"))
      {client, delta} = SseClient.receive_type(client, "text.delta")
      {_client, _metric} = SseClient.receive_type(client, "metric.updated")
      SseClient.close(client)

      last = delta.id

      {fresh, ^session_id, _connected} =
        open_stream(server, session_id, "", [{"last-event-id", last}])

      {fresh, _snapshot} = SseClient.receive_type(fresh, "session.snapshot")
      {_fresh, replayed} = SseClient.receive_json(fresh)
      assert replayed.data["sequence"] > String.to_integer(last)
    end

    test "position 0 replays the whole log", %{directory: directory} do
      server = start_server(directory)
      {client, session_id, connected} = open_stream(server)
      post_message(server, connection_token(connected), prompt("echo hello"))
      {client, _metric} = SseClient.receive_type(client, "metric.updated")
      SseClient.close(client)

      {fresh, ^session_id, _connected} = open_stream(server, session_id, "&last_sequence=0")
      {fresh, _snapshot} = SseClient.receive_type(fresh, "session.snapshot")
      {_fresh, first} = SseClient.receive_json(fresh)
      assert first.data["type"] == "prompt.accepted"
    end
  end

  describe "keeping the stream alive and clean" do
    test "a heartbeat arrives on schedule and carries no id", %{directory: directory} do
      server = start_server(directory, heartbeat_ms: 50, idle_timeout_ms: 5_000)
      {client, _session_id, _connected} = open_stream(server)

      {_client, heartbeat} = SseClient.receive_type(client, "heartbeat")
      assert heartbeat.id == nil
    end

    test "when the client leaves, the channel forgets the stream", %{directory: directory} do
      server = start_server(directory, heartbeat_ms: 50, idle_timeout_ms: 5_000)
      {client, session_id, _connected} = open_stream(server)
      [{channel, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
      assert map_size(:sys.get_state(channel).sockets) == 1

      SseClient.close(client)
      wait_until(fn -> map_size(:sys.get_state(channel).sockets) == 0 end)
    end

    test "when the session stops, the stream says so and ends", %{directory: directory} do
      server = start_server(directory)
      {client, session_id, _connected} = open_stream(server)

      Mead.stop_session(session_id)

      {client, closed} = read_until_event(client, "closed")
      assert JSON.decode!(closed.data) == %{"reason" => "session closed"}
      assert {_client, :closed} = SseClient.receive_event(client)
    end
  end

  describe "a choice answered in words, over SSE" do
    test "the typed answer settles the request", %{directory: directory} do
      server = start_server(directory)
      {client, _session_id, connected} = open_stream(server)
      token = connection_token(connected)

      post_message(server, token, prompt("choosefree a,b"))
      {client, requested} = SseClient.receive_type(client, "choice.requested")
      assert requested.data["payload"]["allow_free_text"] == true

      response =
        post_message(server, token, %{
          "type" => "choice.respond",
          "payload" => %{
            "request_id" => requested.data["payload"]["request_id"],
            "text" => "neither"
          }
        })

      assert response.status == 202
      {client, resolved} = SseClient.receive_type(client, "choice.resolved")
      assert resolved.data["payload"]["text"] == "neither"
      {_client, answer} = SseClient.receive_type(client, "text.delta")
      assert answer.data["payload"]["text"] == "typed neither"
    end
  end

  defp read_until_event(client, name) do
    case SseClient.receive_event(client) do
      {client, %{event: ^name} = event} -> {client, event}
      {client, %{}} -> read_until_event(client, name)
      {_client, other} -> flunk("expected the #{name} event, got #{inspect(other)}")
    end
  end
end
