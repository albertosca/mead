defmodule Mead.Deck.SocketTest do
  # Talks to a real listener and changes the global :storage setting.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mead.Test.DeckServer
  alias Mead.Test.WebSocketClient

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

  defp connected(directory, deck_settings \\ []) do
    server = DeckServer.start(directory, deck_settings)
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    {server, session_id, ticket}
  end

  defp socket_path(ticket), do: "/deck/socket?ticket=" <> ticket

  test "resume answers a snapshot with the session id and no sequence", %{directory: directory} do
    {server, session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)

    {_client, snapshot} = WebSocketClient.receive_json(client)

    assert %{"type" => "session.snapshot", "sequence" => nil, "session_id" => ^session_id} =
             snapshot
  end

  test "a full turn arrives as prompt.accepted, text.delta and metric.updated", %{
    directory: directory
  } do
    {server, _session_id, ticket} = connected(directory)
    client = server |> DeckServer.open(ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    client = DeckServer.send_prompt(client, "echo hello deck", "m-1")

    {client, accepted} = WebSocketClient.receive_type(client, "prompt.accepted")
    assert accepted["payload"]["client_message_id"] == "m-1"

    {client, delta} = WebSocketClient.receive_type(client, "text.delta")
    assert delta["payload"]["text"] == "hello deck"

    {_client, metric} = WebSocketClient.receive_type(client, "metric.updated")
    assert metric["payload"]["unit"] == "tokens"
    assert accepted["sequence"] < delta["sequence"]
  end

  test "a second connection with the same ticket is refused", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory)
    first = DeckServer.open(server, ticket)

    assert {:error, 401, _body} = WebSocketClient.connect(server.port, socket_path(ticket))
    WebSocketClient.close(first)
  end

  test "of two simultaneous attempts with one ticket exactly one upgrades", %{
    directory: directory
  } do
    {server, _session_id, ticket} = connected(directory)

    results =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          case WebSocketClient.connect(server.port, socket_path(ticket)) do
            {:ok, client} ->
              WebSocketClient.close(client)
              :upgraded

            {:error, status, _body} ->
              status
          end
        end)
      end)
      |> Task.await_many()

    assert Enum.sort(results, :desc) == [:upgraded, 401]
  end

  test "heartbeats arrive on their own and keep arriving while a turn is blocked", %{
    directory: directory
  } do
    {server, session_id, ticket} = connected(directory, heartbeat_ms: 100)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    {client, heartbeat} = WebSocketClient.receive_type(client, "heartbeat", 1_000)
    assert heartbeat["sequence"] == nil
    assert heartbeat["session_id"] == session_id

    client = DeckServer.send_prompt(client, "block heartbeat")
    assert_receive {:handler_started, handler, "block heartbeat"}, 2_000

    {client, _heartbeat} = WebSocketClient.receive_type(client, "heartbeat", 1_000)
    {_client, _heartbeat} = WebSocketClient.receive_type(client, "heartbeat", 1_000)

    send(handler, :release)
  end

  test "no session.resume within the deadline closes the socket", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory, resume_deadline_ms: 100)
    {:ok, client} = WebSocketClient.connect(server.port, socket_path(ticket))

    assert {_client, {:close, 1008, "session.resume expected"}} =
             WebSocketClient.receive_frame(client, 2_000)
  end

  test "a first message other than session.resume closes the socket", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory)
    {:ok, client} = WebSocketClient.connect(server.port, socket_path(ticket))
    client = DeckServer.send_prompt(client, "echo too early")

    assert {_client, {:close, 1008, _reason}} = WebSocketClient.receive_frame(client, 2_000)
  end

  test "garbage frames are ignored and the socket still answers a valid message", %{
    directory: directory
  } do
    {server, _session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    oversized =
      JSON.encode!(%{
        "type" => "prompt.send",
        "payload" => %{"client_message_id" => "m", "text" => String.duplicate("a", 65_600)}
      })

    garbage = [
      {:binary, <<0, 1, 2>>},
      {:text, "this is not json"},
      {:text, "[1,2]"},
      {:text, JSON.encode!(%{"type" => "bogus", "payload" => %{}})},
      {:text, JSON.encode!(%{"type" => "prompt.send", "payload" => %{"text" => ""}})},
      {:text, oversized}
    ]

    log =
      capture_log(fn ->
        client = Enum.reduce(garbage, client, &WebSocketClient.send_frame(&2, &1))
        client = DeckServer.send_prompt(client, "echo still alive")
        {_client, delta} = WebSocketClient.receive_type(client, "text.delta")
        assert delta["payload"]["text"] == "still alive"
      end)

    refute log =~ "this is not json"
    refute log =~ "still alive"
  end

  test "a frame over the transport bound closes the connection", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    capture_log(fn ->
      client = WebSocketClient.send_frame(client, {:text, String.duplicate("a", 1_048_577)})

      assert {_client, {:close, 1009, _reason}} = WebSocketClient.receive_frame(client, 2_000)
    end)
  end

  test "more than 20 invalid frames in a minute close the socket", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    capture_log(fn ->
      client =
        Enum.reduce(1..25, client, fn _frame, current ->
          WebSocketClient.send_frame(current, {:text, "garbage"})
        end)

      assert {_client, {:close, 1008, "too many invalid frames"}} =
               WebSocketClient.receive_frame(client, 2_000)
    end)
  end

  test "twenty invalid frames are tolerated", %{directory: directory} do
    {server, _session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    capture_log(fn ->
      client =
        Enum.reduce(1..20, client, fn _frame, current ->
          WebSocketClient.send_frame(current, {:text, "garbage"})
        end)

      client = DeckServer.send_prompt(client, "echo fine")
      {_client, delta} = WebSocketClient.receive_type(client, "text.delta")
      assert delta["payload"]["text"] == "fine"
    end)
  end

  test "a reconnect with last_sequence replays what was missed", %{directory: directory} do
    {server, session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    client = DeckServer.send_prompt(client, "echo first")
    {client, first_delta} = WebSocketClient.receive_type(client, "text.delta")
    {client, _metric} = WebSocketClient.receive_type(client, "metric.updated")
    WebSocketClient.close(client)

    # Missed while disconnected: the turn runs with nobody attached.
    :ok =
      Mead.Deck.Channel.client_message(
        channel_of(session_id),
        self(),
        {:prompt_send, %{client_message_id: "ignored", text: "echo ignored"}}
      )

    %{"ticket" => next_ticket} = DeckServer.ticket(server, session_id)
    client = DeckServer.open(server, next_ticket, first_delta["sequence"])
    {client, snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    assert snapshot["session_id"] == session_id

    {_client, replayed} = WebSocketClient.receive_json(client)
    assert replayed["sequence"] > first_delta["sequence"]
  end

  test "two sockets on one session both receive the live events", %{directory: directory} do
    {server, session_id, ticket} = connected(directory)
    first = DeckServer.open(server, ticket)
    {first, _snapshot} = WebSocketClient.receive_type(first, "session.snapshot")

    %{"ticket" => other_ticket} = DeckServer.ticket(server, session_id)
    second = DeckServer.open(server, other_ticket)
    {second, _snapshot} = WebSocketClient.receive_type(second, "session.snapshot")

    first = DeckServer.send_prompt(first, "echo to both")

    {_first, first_delta} = WebSocketClient.receive_type(first, "text.delta")
    {_second, second_delta} = WebSocketClient.receive_type(second, "text.delta")

    assert first_delta["payload"]["text"] == "to both"
    assert second_delta == first_delta
  end

  test "stopping the session closes the socket", %{directory: directory} do
    {server, session_id, ticket} = connected(directory)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    :ok = Mead.stop_session(session_id)

    assert {_client, {:close, 1011, "session closed"}} =
             WebSocketClient.receive_frame(client, 2_000)
  end

  defp channel_of(session_id) do
    [{pid, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
    pid
  end
end
