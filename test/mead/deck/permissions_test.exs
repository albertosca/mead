defmodule Mead.Deck.PermissionsTest do
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

  defp connect(server, session_id \\ nil, last_sequence \\ 0) do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server, session_id)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket, last_sequence)
    {client, snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    {client, session_id, snapshot}
  end

  # Every sequenced event up to and including the first of `type`, heartbeats left out.
  defp events_until(client, type, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 3_000)
    assert is_map(envelope), "expected an event before #{type}, got #{inspect(envelope)}"

    if envelope["type"] == "heartbeat" do
      events_until(client, type, collected)
    else
      collected = collected ++ [envelope]

      if envelope["type"] == type,
        do: {client, collected},
        else: events_until(client, type, collected)
    end
  end

  defp types(events), do: Enum.map(events, & &1["type"])

  defp respond(client, request_id, option_id) do
    WebSocketClient.send_json(client, %{
      "type" => "permission.respond",
      "payload" => %{"request_id" => request_id, "option_id" => option_id}
    })
  end

  defp set_policy(client, level) do
    WebSocketClient.send_json(client, %{"type" => "policy.set", "payload" => %{"level" => level}})
  end

  defp channel_of(session_id) do
    [{pid, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
    pid
  end

  test "a new session starts at ask_for_risky", %{directory: directory} do
    {_client, _session_id, snapshot} = connect(start_server(directory))
    assert snapshot["payload"]["permission_policy_level"] == "ask_for_risky"
  end

  test "ask_always asks even for a read call", %{directory: directory} do
    {client, _session_id, _snapshot} =
      connect(start_server(directory, default_policy_level: :ask_always))

    client = DeckServer.send_prompt(client, "ask read files__list_directory /a")

    {_client, events} = events_until(client, "permission.requested")
    assert types(events) == ["prompt.accepted", "tool_call.updated", "permission.requested"]

    payload = List.last(events)["payload"]
    assert payload["risk_level"] == "low"
    assert payload["action"] =~ "list_directory"
    assert payload["action"] =~ "files"
    assert payload["details"] == ["argument: /a"]

    assert payload["detail_items"] == [
             %{"key" => "argument", "value" => "/a", "label" => "Argument"}
           ]

    assert is_binary(payload["request_id"]) and is_binary(payload["expires_at"])

    assert payload["options"] == [
             %{"option_id" => "allow_once", "label" => "Allow once", "kind" => "allow_once"},
             %{
               "option_id" => "allow_always",
               "label" => "Always allow this tool",
               "kind" => "allow_always"
             },
             %{"option_id" => "reject_once", "label" => "Reject", "kind" => "reject_once"}
           ]
  end

  test "ask_for_risky runs a read call without asking", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    client = DeckServer.send_prompt(client, "ask read files__list_directory /a")

    {_client, events} = events_until(client, "text.delta")

    assert types(events) ==
             [
               "prompt.accepted",
               "tool_call.updated",
               "tool_call.updated",
               "tool_call.updated",
               "text.delta"
             ]

    assert events
           |> Enum.filter(&(&1["type"] == "tool_call.updated"))
           |> Enum.map(& &1["payload"]["status"]) ==
             ["pending", "in_progress", "completed"]

    assert List.last(events)["payload"]["text"] == "allowed"
  end

  test "ask_for_risky asks for an effect call with high risk", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")

    {_client, events} = events_until(client, "permission.requested")
    assert List.last(events)["payload"]["risk_level"] == "high"
  end

  test "allow_all emits requested then resolved by policy and runs the call", %{
    directory: directory
  } do
    {client, _session_id, _snapshot} =
      connect(start_server(directory, default_policy_level: :allow_all))

    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")

    {_client, events} = events_until(client, "text.delta")

    assert types(events) ==
             [
               "prompt.accepted",
               "tool_call.updated",
               "permission.requested",
               "permission.resolved",
               "tool_call.updated",
               "tool_call.updated",
               "text.delta"
             ]

    requested = Enum.at(events, 2)["payload"]
    resolved = Enum.at(events, 3)["payload"]
    assert resolved["request_id"] == requested["request_id"]
    assert resolved["outcome"] == "allowed"
    assert resolved["decided_by_policy"] == "allow_all"
    refute Map.has_key?(resolved, "decided_by_device")
    assert List.last(events)["payload"]["text"] == "allowed"
  end

  test "a decision is attributed to the device_id the client resumed with", %{
    directory: directory
  } do
    server = start_server(directory)
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open_as(server, ticket, "phone-7")
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    client = respond(client, request_id, "allow_once")
    {_client, after_answer} = events_until(client, "text.delta")

    assert hd(after_answer)["payload"]["decided_by_device"] == "phone-7"
  end

  test "allow_once resolves allowed and runs the call", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    client = respond(client, request_id, "allow_once")
    {_client, after_answer} = events_until(client, "text.delta")

    assert types(after_answer) ==
             ["permission.resolved", "tool_call.updated", "tool_call.updated", "text.delta"]

    resolved = hd(after_answer)["payload"]
    assert resolved["outcome"] == "allowed"
    assert resolved["decided_by_device"] == "device-1"
    assert is_binary(resolved["decided_at"])
    refute Map.has_key?(resolved, "decided_by_policy")
    assert List.last(after_answer)["payload"]["text"] == "allowed"
  end

  test "reject_once resolves rejected and the model sees the denial", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")

    client = respond(client, List.last(events)["payload"]["request_id"], "reject_once")
    {_client, after_answer} = events_until(client, "text.delta")

    assert hd(after_answer)["payload"]["outcome"] == "rejected"
    assert List.last(after_answer)["payload"]["text"] == "denied rejected"
    assert after_answer |> Enum.at(1) |> get_in(["payload", "status"]) == "failed"
  end

  test "a second answer re-sends the resolved to the answering socket only", %{
    directory: directory
  } do
    server = start_server(directory)
    {first, session_id, _snapshot} = connect(server)
    {second, _session_id, _snapshot} = connect(server, session_id)

    first = DeckServer.send_prompt(first, "ask effect files__write_file /a")
    {first, events} = events_until(first, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    first = respond(first, request_id, "allow_once")
    {first, answered} = events_until(first, "text.delta")
    resolved = hd(answered)

    second = respond(second, request_id, "reject_once")
    {second, resent} = events_until(second, "permission.resolved")

    assert resent |> List.last() |> Map.take(["sequence", "payload"]) ==
             Map.take(resolved, ["sequence", "payload"])

    # The first socket only gets the turn's closing metrics, not a second resolved.
    {_first, rest} = events_until(first, "metric.updated")
    refute "permission.resolved" in types(rest)
    WebSocketClient.close(second)
  end

  test "an unknown request id and an option that was not offered are ignored", %{
    directory: directory
  } do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    client =
      client |> respond("request-unknown", "allow_once") |> respond(request_id, "allow_forever")

    client = respond(client, request_id, "allow_once")

    {_client, after_answer} = events_until(client, "text.delta")
    assert hd(after_answer)["payload"]["outcome"] == "allowed"
  end

  test "the deadline expires the request and the turn goes on with the denial", %{
    directory: directory
  } do
    {client, _session_id, _snapshot} =
      connect(start_server(directory, permission_timeout_ms: 100))

    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    {client, after_deadline} = events_until(client, "text.delta")
    resolved = hd(after_deadline)["payload"]
    assert resolved["outcome"] == "expired"
    refute Map.has_key?(resolved, "decided_by_device")
    assert List.last(after_deadline)["payload"]["text"] == "denied expired"

    # A late answer gets the expired resolved again.
    client = respond(client, request_id, "allow_once")
    {_client, resent} = events_until(client, "permission.resolved")
    assert List.last(resent)["payload"]["outcome"] == "expired"
  end

  test "the turn clock is paused while a request waits", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory, [], 200))
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, events} = events_until(client, "permission.requested")

    Process.sleep(450)
    client = respond(client, List.last(events)["payload"]["request_id"], "allow_once")

    {_client, after_answer} = events_until(client, "text.delta")
    assert List.last(after_answer)["payload"]["text"] == "allowed"
  end

  test "a deck that reconnects after the deadline replays requested then expired", %{
    directory: directory
  } do
    server = start_server(directory, permission_timeout_ms: 150)
    {client, session_id, _snapshot} = connect(server)
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, _events} = events_until(client, "permission.requested")
    WebSocketClient.close(client)

    Process.sleep(400)
    {client, _session_id, _snapshot} = connect(server, session_id)
    {_client, replayed} = events_until(client, "permission.resolved")

    assert types(replayed) |> Enum.filter(&String.starts_with?(&1, "permission.")) ==
             ["permission.requested", "permission.resolved"]

    assert List.last(replayed)["payload"]["outcome"] == "expired"
  end

  test "a restarted channel closes the requests the dead one left open", %{directory: directory} do
    server = start_server(directory)
    {client, session_id, _snapshot} = connect(server)
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, _events} = events_until(client, "permission.requested")

    capture_log(fn ->
      Process.exit(channel_of(session_id), :kill)
      WebSocketClient.close(client)
      Process.sleep(100)

      {client, _session_id, _snapshot} = connect(server, session_id)
      {_client, replayed} = events_until(client, "permission.resolved")

      assert List.last(replayed)["payload"]["outcome"] == "expired"
    end)
  end

  test "policy.set reaches every socket, applies to later requests only, and survives a restart",
       %{
         directory: directory
       } do
    server = start_server(directory, default_policy_level: :ask_always)
    {first, session_id, _snapshot} = connect(server)
    {second, _session_id, _snapshot} = connect(server, session_id)

    first = DeckServer.send_prompt(first, "ask read files__list_directory /a")
    {first, events} = events_until(first, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    first = set_policy(first, "allow_all")
    {first, [updated]} = events_until(first, "policy.updated")
    assert updated["payload"] == %{"level" => "allow_all"}
    {second, seen_by_second} = events_until(second, "policy.updated")
    assert List.last(seen_by_second)["payload"] == %{"level" => "allow_all"}
    WebSocketClient.close(second)

    # The open request keeps waiting.
    first = respond(first, request_id, "allow_once")
    {first, answered} = events_until(first, "text.delta")
    assert hd(answered)["payload"]["decided_by_device"] == "device-1"

    # A later request is decided by the new level.
    first = DeckServer.send_prompt(first, "ask effect files__write_file /b")
    {first, later} = events_until(first, "text.delta")

    assert Enum.find(later, &(&1["type"] == "permission.resolved"))["payload"][
             "decided_by_policy"
           ] == "allow_all"

    WebSocketClient.close(first)

    capture_log(fn ->
      Process.exit(channel_of(session_id), :kill)
      Process.sleep(100)
      {client, _session_id, snapshot} = connect(server, session_id)
      assert snapshot["payload"]["permission_policy_level"] == "allow_all"
      WebSocketClient.close(client)
    end)
  end

  test "policy.set with an unknown level changes nothing", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))

    capture_log(fn ->
      client = set_policy(client, "bogus")
      client = DeckServer.send_prompt(client, "echo still fine")
      {_client, events} = events_until(client, "text.delta")
      refute "policy.updated" in types(events)
    end)
  end

  test "details are cut at 2000 characters and the value is never logged", %{directory: directory} do
    {client, _session_id, _snapshot} = connect(start_server(directory))
    secret = "SECRETVALUE" <> String.duplicate("x", 3_000)

    log =
      capture_log(fn ->
        client = DeckServer.send_prompt(client, "ask effect files__write_file " <> secret)
        {client, events} = events_until(client, "permission.requested")
        [detail] = List.last(events)["payload"]["details"]
        assert detail == "argument: " <> String.slice(secret, 0, 2_000)

        client = respond(client, List.last(events)["payload"]["request_id"], "reject_once")
        events_until(client, "text.delta")
      end)

    refute log =~ "SECRETVALUE"
  end

  test "requests of two sessions never cross", %{directory: directory} do
    server = start_server(directory)
    {first, _first_id, _snapshot} = connect(server)
    {second, _second_id, _snapshot} = connect(server)

    first = DeckServer.send_prompt(first, "ask effect files__write_file /a")
    {first, events} = events_until(first, "permission.requested")
    request_id = List.last(events)["payload"]["request_id"]

    second = respond(second, request_id, "allow_once")
    {_second, nothing} = WebSocketClient.receive_json(second, 300)
    assert nothing == :timeout

    first = respond(first, request_id, "reject_once")
    {_first, answered} = events_until(first, "text.delta")
    assert hd(answered)["payload"]["outcome"] == "rejected"
  end
end
