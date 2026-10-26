defmodule Mead.Deck.ChoicesTest do
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

  defp start_server(directory, deck_settings \\ [], turn_timeout \\ 5_000) do
    DeckServer.start(directory, deck_settings,
      session_options: [handler: Mead.Test.DeckHandler, turn_timeout: turn_timeout]
    )
  end

  defp connect(server, session_id \\ nil) do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server, session_id)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    {client, session_id}
  end

  defp events_until(client, type, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 3_000)
    assert is_map(envelope), "expected an event before #{type}, got #{inspect(envelope)}"

    cond do
      envelope["type"] == "heartbeat" -> events_until(client, type, collected)
      envelope["type"] == type -> {client, collected ++ [envelope]}
      true -> events_until(client, type, collected ++ [envelope])
    end
  end

  defp choose(client, request_id, option_id) do
    WebSocketClient.send_json(client, %{
      "type" => "choice.respond",
      "payload" => %{"request_id" => request_id, "option_id" => option_id}
    })
  end

  defp ask(client, identifiers \\ "a,b") do
    client = DeckServer.send_prompt(client, "choose " <> identifiers)
    {client, events} = events_until(client, "choice.requested")
    {client, List.last(events)["payload"]}
  end

  test "a choice is requested with its options and the first answer wins", %{directory: directory} do
    {client, _session_id} = connect(start_server(directory))
    {client, requested} = ask(client)

    assert requested["prompt"] == "Which one?"

    assert requested["options"] == [
             %{"id" => "a", "label" => "Label a"},
             %{"id" => "b", "label" => "Label b"}
           ]

    client = choose(client, requested["request_id"], "b")
    {client, resolved} = events_until(client, "choice.resolved")
    payload = List.last(resolved)["payload"]
    assert payload["request_id"] == requested["request_id"]
    assert payload["option_id"] == "b"
    assert payload["decided_by_device"] =~ "device-"

    {_client, answer} = events_until(client, "text.delta")
    assert List.last(answer)["payload"]["text"] == "chose b"
  end

  test "an option that was not offered and an unknown request are ignored", %{
    directory: directory
  } do
    {client, _session_id} = connect(start_server(directory))
    {client, requested} = ask(client)

    client = choose(client, requested["request_id"], "zzz")
    client = choose(client, "no-such-request", "a")
    assert {client, :timeout} = WebSocketClient.receive_json(client, 200)

    client = choose(client, requested["request_id"], "a")
    {_client, resolved} = events_until(client, "choice.resolved")
    assert List.last(resolved)["payload"]["option_id"] == "a"
  end

  test "a repeated answer re-sends the resolved to that socket only", %{directory: directory} do
    server = start_server(directory)
    {first, session_id} = connect(server)
    {second, _session_id} = connect(server, session_id)
    {first, requested} = ask(first)

    first = choose(first, requested["request_id"], "a")
    {first, _events} = events_until(first, "choice.resolved")
    {second, _events} = events_until(second, "choice.resolved")
    {first, _events} = events_until(first, "metric.updated")
    {second, _events} = events_until(second, "metric.updated")

    second = choose(second, requested["request_id"], "b")
    {_second, resent} = events_until(second, "choice.resolved")
    assert List.last(resent)["payload"]["option_id"] == "a"
    refute "choice.resolved" in types_until_quiet(first)
  end

  # Whatever else arrives (a late metric, a heartbeat) until the socket is quiet for a moment.
  defp types_until_quiet(client, types \\ []) do
    case WebSocketClient.receive_json(client, 200) do
      {_client, :timeout} -> types
      {client, envelope} -> types_until_quiet(client, types ++ [envelope["type"]])
    end
  end

  test "a permission answer cannot settle a choice", %{directory: directory} do
    {client, _session_id} = connect(start_server(directory))
    {client, requested} = ask(client)

    client =
      WebSocketClient.send_json(client, %{
        "type" => "permission.respond",
        "payload" => %{"request_id" => requested["request_id"], "option_id" => "allow_once"}
      })

    refute "choice.resolved" in types_until_quiet(client)
    client = choose(client, requested["request_id"], "a")
    {_client, resolved} = events_until(client, "choice.resolved")
    assert List.last(resolved)["payload"]["option_id"] == "a"
  end

  test "the deadline resolves the choice with no option and the turn goes on", %{
    directory: directory
  } do
    {client, _session_id} = connect(start_server(directory, permission_timeout_ms: 150))
    {client, requested} = ask(client)

    {client, resolved} = events_until(client, "choice.resolved")
    payload = List.last(resolved)["payload"]
    assert payload["request_id"] == requested["request_id"]
    assert payload["option_id"] == nil
    assert Map.has_key?(payload, "option_id")

    {_client, answer} = events_until(client, "text.delta")
    assert List.last(answer)["payload"]["text"] == "no choice expired"
  end

  test "the turn clock is paused while a choice waits", %{directory: directory} do
    {client, _session_id} = connect(start_server(directory, [], 200))
    {client, requested} = ask(client)

    Process.sleep(450)
    client = choose(client, requested["request_id"], "a")

    {_client, answer} = events_until(client, "text.delta")
    assert List.last(answer)["payload"]["text"] == "chose a"
  end

  test "a restarted channel closes the choice the dead one left open", %{directory: directory} do
    server = start_server(directory)
    {client, session_id} = connect(server)
    {client, _requested} = ask(client)

    capture_log(fn ->
      [{pid, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
      Process.exit(pid, :kill)
      WebSocketClient.close(client)
      Process.sleep(100)

      {client, _session_id} = connect(server, session_id)
      {_client, replayed} = events_until(client, "choice.resolved")
      assert List.last(replayed)["payload"]["option_id"] == nil
    end)
  end
end
