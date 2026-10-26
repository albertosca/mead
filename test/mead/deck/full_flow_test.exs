defmodule Mead.Deck.FullFlowTest do
  # One session through the real listener and WebSocket: a streamed answer, a tool call that needs
  # permission, a cancellation, an ask_user choice, and a reconnect that replays everything. Only
  # the model and the tool server are scripted.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
  alias Mead.Test.StreamingProvider
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir

  @tools [
    %{name: "files__write_file", description: "Write", input_schema: %{"type" => "object"}},
    %{name: "files__slow_job", description: "Slow", input_schema: %{"type" => "object"}}
  ]

  @question %{
    "prompt" => "Which one?",
    "options" => [%{"id" => "a", "label" => "Alpha"}, %{"id" => "b", "label" => "Beta"}]
  }

  setup %{tmp_dir: directory} do
    previous_storage = Application.get_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      Application.delete_env(:mead, :tool_handler)

      case previous_storage do
        nil -> Application.delete_env(:mead, :storage)
        value -> Application.put_env(:mead, :storage, value)
      end
    end)

    %{directory: directory}
  end

  defp script_session do
    steps = [
      FakeProvider.text_step("alpha"),
      FakeProvider.tool_step([{"call-2", "files__write_file", %{"path" => "/a"}}]),
      FakeProvider.text_step("beta"),
      FakeProvider.tool_step([{"call-3", "files__slow_job", %{}}]),
      FakeProvider.text_step("gamma"),
      FakeProvider.tool_step([{"call-4", "ask_user", @question}]),
      FakeProvider.text_step("delta")
    ]

    {:ok, script} = Agent.start_link(fn -> steps end)
    slot = {StreamingProvider, test_pid: self(), script: script}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: slot, cloud: slot],
      hub: [
        test_pid: self(),
        tools: @tools,
        classes: %{"files__write_file" => :effect, "files__slow_job" => :effect},
        results: %{
          "files__write_file" => {:ok, %{content: "written", is_error: false}},
          "files__slow_job" => :block
        }
      ]
    })
  end

  defp next_event(client) do
    {client, envelope} = WebSocketClient.receive_json(client, 5_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    if envelope["type"] == "heartbeat", do: next_event(client), else: {client, envelope}
  end

  # Reads events until `matches?` accepts one; returns everything read, that event last.
  defp read_until(client, matches?, collected \\ []) do
    {client, envelope} = next_event(client)
    collected = collected ++ [envelope]

    if matches?.(envelope), do: {client, collected}, else: read_until(client, matches?, collected)
  end

  defp until_type(client, type), do: read_until(client, &(&1["type"] == type))

  defp until_turn_end(client),
    do:
      read_until(
        client,
        &(&1["type"] == "metric.updated" and &1["payload"]["key"] == "tokens_out")
      )

  defp types(events), do: Enum.map(events, & &1["type"])

  defp statuses(events),
    do:
      for(%{"type" => "tool_call.updated", "payload" => payload} <- events, do: payload["status"])

  defp send_message(client, type, payload),
    do: WebSocketClient.send_json(client, %{"type" => type, "payload" => payload})

  test "one session end to end, then a reconnect replays it all", %{directory: directory} do
    script_session()

    server =
      DeckServer.start(directory, [],
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 10_000]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    # Turn 1: a streamed answer.
    client = DeckServer.send_prompt(client, "one")
    {client, first} = until_turn_end(client)

    assert types(first) == [
             "prompt.accepted",
             "text.delta",
             "text.delta",
             "metric.updated",
             "metric.updated"
           ]

    assert Enum.join(
             for(%{"type" => "text.delta", "payload" => %{"text" => text}} <- first, do: text)
           ) == "alpha"

    # Turn 2: a tool call that needs permission, allowed.
    client = DeckServer.send_prompt(client, "two")
    {client, asked} = until_type(client, "permission.requested")
    request_id = List.last(asked)["payload"]["request_id"]

    client =
      send_message(client, "permission.respond", %{
        "request_id" => request_id,
        "option_id" => "allow_once"
      })

    {client, second_rest} = until_turn_end(client)
    second = asked ++ second_rest

    assert types(second) ==
             [
               "prompt.accepted",
               "tool_call.updated",
               "permission.requested",
               "permission.resolved",
               "tool_call.updated",
               "tool_call.updated",
               "text.delta",
               "text.delta",
               "metric.updated",
               "metric.updated"
             ]

    assert statuses(second) == ["pending", "in_progress", "completed"]

    # Turn 3: a tool call allowed and then cancelled while it runs.
    client = DeckServer.send_prompt(client, "three")
    {client, asked} = until_type(client, "permission.requested")
    request_id = List.last(asked)["payload"]["request_id"]

    client =
      send_message(client, "permission.respond", %{
        "request_id" => request_id,
        "option_id" => "allow_once"
      })

    {client, running} = read_until(client, &(&1["payload"]["status"] == "in_progress"))
    assert_receive {:tool_blocked, _pid}, 2_000
    assert List.last(running)["payload"]["cancellable"] == true
    client = send_message(client, "tool_call.cancel", %{"tool_call_id" => "call-3"})
    {client, third_rest} = until_turn_end(client)
    third = asked ++ running ++ third_rest

    assert statuses(third) == ["pending", "in_progress", "failed"]

    assert Enum.find(third, &(&1["payload"]["status"] == "failed"))["payload"]["current_step"] ==
             "cancelled"

    # Turn 4: the model asks the person to choose.
    client = DeckServer.send_prompt(client, "four")
    {client, asked} = until_type(client, "choice.requested")
    request_id = List.last(asked)["payload"]["request_id"]

    client =
      send_message(client, "choice.respond", %{"request_id" => request_id, "option_id" => "b"})

    {client, fourth_rest} = until_turn_end(client)
    fourth = asked ++ fourth_rest

    assert types(fourth) ==
             [
               "prompt.accepted",
               "choice.requested",
               "choice.resolved",
               "text.delta",
               "text.delta",
               "metric.updated",
               "metric.updated"
             ]

    assert Enum.at(fourth, 2)["payload"]["option_id"] == "b"

    live = first ++ second ++ third ++ fourth
    sequences = Enum.map(live, & &1["sequence"])

    assert sequences == Enum.to_list(hd(sequences)..List.last(sequences)),
           "the sequence has a gap"

    WebSocketClient.close(client)

    # A reconnect from zero replays every event, in the same order with the same sequences.
    %{"ticket" => second_ticket} = DeckServer.ticket(server, session_id)
    replay_client = DeckServer.open(server, second_ticket, 0)
    {replay_client, snapshot} = WebSocketClient.receive_type(replay_client, "session.snapshot")
    assert snapshot["session_id"] == session_id

    {_replay_client, replayed} =
      Enum.reduce(live, {replay_client, []}, fn _event, {current, collected} ->
        {current, envelope} = next_event(current)
        {current, collected ++ [envelope]}
      end)

    assert Enum.map(replayed, &{&1["sequence"], &1["type"]}) ==
             Enum.map(live, &{&1["sequence"], &1["type"]})
  end
end
