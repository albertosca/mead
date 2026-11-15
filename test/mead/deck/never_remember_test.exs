defmodule Mead.Deck.NeverRememberTest do
  # A tool the operator marked `never_remember` is confirmed on every call: at every policy level,
  # without the "always allow" option, and whatever the log remembers from before it was marked.
  use ExUnit.Case, async: false

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

    server = DeckServer.start(directory, [])
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket, 0)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    %{client: client}
  end

  defp events_until(client, matches?, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 15_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    if envelope["type"] == "heartbeat" do
      events_until(client, matches?, collected)
    else
      collected = collected ++ [envelope]

      if matches?.(envelope),
        do: {client, collected},
        else: events_until(client, matches?, collected)
    end
  end

  defp until_type(client, type), do: events_until(client, &(&1["type"] == type))

  defp until_turn_end(client),
    do:
      events_until(
        client,
        &(&1["type"] == "metric.updated" and &1["payload"]["key"] == "tokens_out")
      )

  defp send_message(client, type, payload),
    do: WebSocketClient.send_json(client, %{"type" => type, "payload" => payload})

  defp set_policy(client, level) do
    client = send_message(client, "policy.set", %{"level" => level})
    {client, _policy} = until_type(client, "policy.updated")
    client
  end

  defp respond(client, request, option_id) do
    send_message(client, "permission.respond", %{
      "request_id" => request["payload"]["request_id"],
      "option_id" => option_id
    })
  end

  test "asks at allow_all, where an unmarked tool is approved by policy", %{client: client} do
    client = set_policy(client, "allow_all")

    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, unmarked} = until_turn_end(client)
    resolved = Enum.find(unmarked, &(&1["type"] == "permission.resolved"))["payload"]
    assert resolved["decided_by_policy"] == "allow_all"

    client = DeckServer.send_prompt(client, "ask effect! files__write_file /a")
    assert_decided_by_a_person(client)
  end

  # The request is also emitted when a policy approves at once, so the proof that a person was
  # asked is that the resolution carries neither a policy nor a rule as its author.
  defp assert_decided_by_a_person(client) do
    {client, asked} = until_type(client, "permission.requested")
    client = respond(client, List.last(asked), "allow_once")
    {_client, events} = until_turn_end(client)

    assert [%{"payload" => resolved}] =
             Enum.filter(events, &(&1["type"] == "permission.resolved"))

    refute Map.has_key?(resolved, "decided_by_policy")
    refute Map.has_key?(resolved, "decided_by_rule")
  end

  test "asks for a marked read tool at ask_for_risky, which lets a read call through", %{
    client: client
  } do
    client = DeckServer.send_prompt(client, "ask read files__list_directory /a")
    {client, plain} = until_turn_end(client)
    refute Enum.any?(plain, &(&1["type"] == "permission.requested"))

    client = DeckServer.send_prompt(client, "ask read! files__list_directory /a")
    assert_decided_by_a_person(client)
  end

  test "offers only allow_once and reject_once", %{client: client} do
    client = DeckServer.send_prompt(client, "ask effect! files__write_file /a")
    {_client, events} = until_type(client, "permission.requested")

    assert List.last(events)["payload"]["options"] == [
             %{"option_id" => "allow_once", "label" => "Allow once", "kind" => "allow_once"},
             %{"option_id" => "reject_once", "label" => "Reject", "kind" => "reject_once"}
           ]
  end

  test "an allow_always answer to a marked request is ignored and the request stays open", %{
    client: client
  } do
    client = DeckServer.send_prompt(client, "ask effect! files__write_file /a")
    {client, asked} = until_type(client, "permission.requested")
    request = List.last(asked)

    client = respond(client, request, "allow_always")
    client = respond(client, request, "allow_once")
    {client, rest} = until_turn_end(client)

    resolutions = Enum.filter(rest, &(&1["type"] == "permission.resolved"))
    assert [%{"payload" => resolved}] = resolutions
    assert resolved["outcome"] == "allowed"
    refute Map.has_key?(resolved, "remember")

    client = DeckServer.send_prompt(client, "ask effect! files__write_file /b")
    {_client, again} = until_type(client, "permission.requested")
    assert List.last(again)["type"] == "permission.requested"
  end

  test "a rule remembered before the tool was marked does not approve it", %{client: client} do
    client = DeckServer.send_prompt(client, "ask effect files__write_file /a")
    {client, asked} = until_type(client, "permission.requested")
    client = respond(client, List.last(asked), "allow_always")
    {client, _rest} = until_turn_end(client)

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {client, remembered} = until_turn_end(client)
    resolved = Enum.find(remembered, &(&1["type"] == "permission.resolved"))["payload"]
    assert resolved["decided_by_rule"] == "files__write_file"

    client = DeckServer.send_prompt(client, "ask effect! files__write_file /c")
    assert_decided_by_a_person(client)
  end
end
