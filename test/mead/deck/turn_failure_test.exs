defmodule Mead.Deck.TurnFailureTest do
  # What the deck is told when a turn does not end well. The real listener, WebSocket, channel and
  # router; only the model and the tool are scripted.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
  alias Mead.Test.StreamingProvider
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}

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

  defp open(directory, handler, turn_timeout) do
    server =
      DeckServer.start(directory, [],
        session_options: [handler: handler, turn_timeout: turn_timeout]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    {client, session_id}
  end

  defp script_provider(provider, steps, provider_options, results) do
    {:ok, script} = Agent.start_link(fn -> steps end)
    slot = {provider, [test_pid: self(), script: script] ++ provider_options}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: slot, cloud: slot],
      hub: [test_pid: self(), tools: [@tool], results: results]
    })
  end

  # Every sequenced event up to and including the first one that satisfies `done`.
  defp events_until(client, done, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 5_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    cond do
      envelope["type"] == "heartbeat" -> events_until(client, done, collected)
      done.(envelope) -> {client, collected ++ [envelope]}
      true -> events_until(client, done, collected ++ [envelope])
    end
  end

  defp metric?(envelope), do: envelope["type"] == "metric.updated"

  test "a stream that fails midway ends with a turn.failed event after its fragments",
       %{directory: directory} do
    script_provider(
      StreamingProvider,
      [FakeProvider.text_step("fake reply")],
      [fail_after: 2],
      %{}
    )

    {client, _session_id} = open(directory, Mead.Test.ToolHandler, 10_000)

    client = DeckServer.send_prompt(client, "go")
    {_client, events} = events_until(client, &metric?/1)

    types = Enum.map(events, & &1["type"])

    assert types == [
             "prompt.accepted",
             "text.delta",
             "text.delta",
             "turn.failed",
             "metric.updated"
           ]

    failed = Enum.find(events, &(&1["type"] == "turn.failed"))
    assert failed["payload"]["turn_id"] == "turn-1"
    assert failed["payload"]["reason"] == "timeout"
  end

  test "a prompt that the session cannot take because another turn runs is reported as failed",
       %{directory: directory} do
    {client, session_id} = open(directory, Mead.Test.DeckHandler, 10_000)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)

    blocker = Task.async(fn -> Mead.submit_turn(session_id, "block-other") end)
    assert_receive {:handler_started, handler, "block-other"}

    client = DeckServer.send_prompt(client, "echo deck")
    {_client, events} = events_until(client, &metric?/1)

    failed = Enum.find(events, &(&1["type"] == "turn.failed"))
    assert failed["payload"]["reason"] == "turn_in_progress"

    send(handler, :release)
    Task.await(blocker)
  end

  test "a tool call still running when the turn times out is reported as failed",
       %{directory: directory} do
    steps = [
      FakeProvider.tool_step([{"call-1", "files__read_file", %{"path" => "/a"}}]),
      FakeProvider.text_step("done")
    ]

    script_provider(FakeProvider, steps, [], %{"files__read_file" => :block})
    {client, _session_id} = open(directory, Mead.Test.ToolHandler, 400)

    client = DeckServer.send_prompt(client, "read the file")
    {_client, events} = events_until(client, &metric?/1)

    updates = for %{"type" => "tool_call.updated", "payload" => payload} <- events, do: payload
    assert [%{"status" => "pending"}, %{"status" => "in_progress"}, final] = updates
    assert final["status"] == "failed"
    assert final["tool_call_id"] == "call-1"
    assert final["cancellable"] == false
  end
end
