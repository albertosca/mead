defmodule Mead.Deck.RememberedRulesTest do
  # "Always allow this tool": the answer is remembered per session, survives a new channel because
  # it is rebuilt from the log, and can be taken back.
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
    {client, _snapshot} = open(server, ticket)
    %{server: server, client: client, session_id: session_id, directory: directory}
  end

  defp open(server, ticket) do
    client = DeckServer.open(server, ticket, 0)
    WebSocketClient.receive_type(client, "session.snapshot")
  end

  defp reopen(context) do
    %{"ticket" => ticket} = DeckServer.ticket(context.server, context.session_id)
    {client, _snapshot} = open(context.server, ticket)
    client
  end

  defp events_until(client, matches?, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 3_000)
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

  defp types(events), do: Enum.map(events, & &1["type"])

  defp send_message(client, type, payload),
    do: WebSocketClient.send_json(client, %{"type" => type, "payload" => payload})

  # Asks for the write tool and answers the permission request with `option_id`.
  defp ask_and_answer(client, option_id, tool \\ "files__write_file") do
    client = DeckServer.send_prompt(client, "ask effect #{tool} /a")
    {client, asked} = until_type(client, "permission.requested")

    client =
      send_message(client, "permission.respond", %{
        "request_id" => List.last(asked)["payload"]["request_id"],
        "option_id" => option_id
      })

    {client, rest} = until_turn_end(client)
    {client, asked ++ rest}
  end

  defp remember(client) do
    {client, events} = ask_and_answer(client, "allow_always")
    resolved = Enum.find(events, &(&1["type"] == "permission.resolved"))
    assert resolved["payload"]["remember"] == "files__write_file"
    client
  end

  test "allow_always lets the same tool through without asking again", %{client: client} do
    client = remember(client)

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, events} = until_turn_end(client)

    assert types(events) ==
             ~w(prompt.accepted tool_call.updated permission.requested permission.resolved tool_call.updated tool_call.updated text.delta metric.updated metric.updated)

    resolved = Enum.find(events, &(&1["type"] == "permission.resolved"))["payload"]
    assert resolved["outcome"] == "allowed"
    assert resolved["decided_by_rule"] == "files__write_file"
    refute Map.has_key?(resolved, "decided_by_device")
  end

  test "allow_once remembers nothing", %{client: client} do
    {client, events} = ask_and_answer(client, "allow_once")
    resolved = Enum.find(events, &(&1["type"] == "permission.resolved"))["payload"]
    refute Map.has_key?(resolved, "remember")

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, asked} = until_type(client, "permission.requested")
    assert List.last(asked)["type"] == "permission.requested"
  end

  test "another tool still asks", %{client: client} do
    client = remember(client)

    client = DeckServer.send_prompt(client, "ask effect files__delete_file /a")
    {_client, events} = until_type(client, "permission.requested")
    assert types(events) == ["prompt.accepted", "tool_call.updated", "permission.requested"]
  end

  test "a rule beats ask_always", %{client: client} do
    client = remember(client)
    send_message(client, "policy.set", %{"level" => "ask_always"})
    {client, _policy} = until_type(client, "policy.updated")

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, events} = until_turn_end(client)

    resolved = Enum.find(events, &(&1["type"] == "permission.resolved"))["payload"]
    assert resolved["decided_by_rule"] == "files__write_file"
  end

  test "allow_all keeps deciding by policy", %{client: client} do
    client = remember(client)
    send_message(client, "policy.set", %{"level" => "allow_all"})
    {client, _policy} = until_type(client, "policy.updated")

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, events} = until_turn_end(client)

    resolved = Enum.find(events, &(&1["type"] == "permission.resolved"))["payload"]
    assert resolved["decided_by_policy"] == "allow_all"
    refute Map.has_key?(resolved, "decided_by_rule")
  end

  test "a new channel rebuilds the rules from the log", context do
    client = remember(context.client)
    WebSocketClient.close(client)

    [{channel, _value}] = Registry.lookup(Mead.Registry, {:deck, context.session_id})
    monitor = Process.monitor(channel)
    Process.exit(channel, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^channel, _reason}, 2_000

    client = reopen(context)

    {client, _replayed} =
      events_until(
        client,
        &(&1["type"] == "metric.updated" and &1["payload"]["key"] == "tokens_out")
      )

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, events} = events_until(client, &(&1["type"] == "permission.resolved"))
    assert List.last(events)["payload"]["decided_by_rule"] == "files__write_file"
  end

  test "permission.forget takes the rule back", %{client: client} do
    client = remember(client)

    client = send_message(client, "permission.forget", %{"tool" => "files__write_file"})
    {client, forgotten} = until_type(client, "permission.forgotten")
    assert List.last(forgotten)["payload"] == %{"tool" => "files__write_file"}

    client = DeckServer.send_prompt(client, "ask effect files__write_file /b")
    {_client, events} = until_type(client, "permission.requested")
    assert List.last(events)["type"] == "permission.requested"
  end

  test "forgetting a tool nobody remembered says nothing", %{client: client} do
    client = send_message(client, "permission.forget", %{"tool" => "files__write_file"})
    client = DeckServer.send_prompt(client, "echo x")
    {_client, events} = until_type(client, "prompt.accepted")
    assert types(events) == ["prompt.accepted"]
  end
end
