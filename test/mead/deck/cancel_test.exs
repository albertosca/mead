defmodule Mead.Deck.CancelTest do
  # The real listener, WebSocket, channel and router; only the model and the tool are scripted.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
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

  # A blocking read tool; the default policy lets a read call run without asking.
  defp open(directory) do
    steps = [
      FakeProvider.tool_step([{"call-1", "files__read_file", %{"path" => "/a"}}]),
      FakeProvider.text_step("done")
    ]

    {:ok, script} = Agent.start_link(fn -> steps end)
    provider = {FakeProvider, test_pid: self(), script: script}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: provider, cloud: provider],
      hub: [test_pid: self(), tools: [@tool], results: %{"files__read_file" => :block}]
    })

    server =
      DeckServer.start(directory, [],
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 5_000]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    DeckServer.send_prompt(client, "read the file")
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

  defp running_call(client) do
    {client, events} = events_until(client, "tool_call.updated")

    case List.last(events)["payload"] do
      %{"status" => "in_progress"} = payload -> {client, payload}
      _pending -> running_call(client)
    end
  end

  defp cancel(client, tool_call_id) do
    WebSocketClient.send_json(client, %{
      "type" => "tool_call.cancel",
      "payload" => %{"tool_call_id" => tool_call_id}
    })
  end

  defp terminal_updates(events) do
    Enum.filter(events, fn event ->
      event["type"] == "tool_call.updated" and
        event["payload"]["status"] in ["completed", "failed"]
    end)
  end

  test "cancelling a blocked call ends it failed and the turn goes on", %{directory: directory} do
    client = open(directory)
    {client, running} = running_call(client)
    assert running["cancellable"] == true
    assert_receive {:tool_blocked, tool_pid}, 2_000

    client = cancel(client, running["tool_call_id"])
    {_client, events} = events_until(client, "text.delta")

    [terminal] = terminal_updates(events)
    assert terminal["payload"]["status"] == "failed"
    assert terminal["payload"]["current_step"] == "cancelled"
    assert terminal["payload"]["cancellable"] == false
    assert List.last(events)["payload"]["text"] == "done"

    refute Process.alive?(tool_pid)
    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, messages, _tools}
    assert %{content: [result]} = List.last(messages)
    assert result.content == "The person cancelled this tool call."
  end

  test "cancel is idempotent and an unknown id is ignored", %{directory: directory} do
    client = open(directory)
    {client, running} = running_call(client)

    client =
      client
      |> cancel("call-unknown")
      |> cancel(running["tool_call_id"])
      |> cancel(running["tool_call_id"])

    {_client, events} = events_until(client, "text.delta")
    assert [_one] = terminal_updates(events)
  end

  test "a call that finishes as the cancel arrives has exactly one terminal update", %{
    directory: directory
  } do
    client = open(directory)
    {client, running} = running_call(client)
    assert_receive {:tool_blocked, tool_pid}, 2_000

    send(tool_pid, :release)
    client = cancel(client, running["tool_call_id"])

    {client, events} = events_until(client, "text.delta")
    assert [_one] = terminal_updates(events)

    # A cancel after the call ended changes nothing.
    client = cancel(client, running["tool_call_id"])
    {_client, rest} = events_until(client, "metric.updated")
    assert terminal_updates(rest) == []
  end

  test "no clock is left paused by a cancelled call", %{directory: directory} do
    client = open(directory)
    {client, running} = running_call(client)

    client = cancel(client, running["tool_call_id"])
    {_client, events} = events_until(client, "text.delta")

    assert List.last(events)["payload"]["text"] == "done"
  end
end
