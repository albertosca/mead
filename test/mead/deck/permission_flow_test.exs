defmodule Mead.Deck.PermissionFlowTest do
  # The real listener, the real WebSocket, the real channel and the real router; only the model
  # and the tool server are scripted.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir

  @write_tool %{
    name: "files__write_file",
    description: "Write a file",
    input_schema: %{"type" => "object"}
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

  # The model asks for the write tool, then answers "done" once it has the result.
  defp scripted_turn do
    steps = [
      FakeProvider.tool_step([{"call-1", "files__write_file", %{"path" => "/a"}}]),
      FakeProvider.text_step("done")
    ]

    {:ok, script} = Agent.start_link(fn -> steps end)
    provider = {FakeProvider, test_pid: self(), script: script}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: provider, cloud: provider],
      hub: [
        test_pid: self(),
        tools: [@write_tool],
        classes: %{"files__write_file" => :effect},
        results: %{"files__write_file" => {:ok, %{content: "written", is_error: false}}}
      ]
    })
  end

  defp open(directory, deck_settings \\ []) do
    server =
      DeckServer.start(directory, deck_settings,
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 5_000]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    client
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

  defp types(events), do: Enum.map(events, & &1["type"])

  defp respond(client, request_id, option_id) do
    WebSocketClient.send_json(client, %{
      "type" => "permission.respond",
      "payload" => %{"request_id" => request_id, "option_id" => option_id}
    })
  end

  defp ask(client) do
    scripted_turn()
    client = DeckServer.send_prompt(client, "write the file")
    {client, events} = events_until(client, "permission.requested")
    {client, events, List.last(events)["payload"]["request_id"]}
  end

  # The tool result the model received in its second call.
  defp result_seen_by_model do
    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, messages, _tools}
    assert %{role: :user, content: [result]} = List.last(messages)
    result
  end

  test "an allowed call runs the tool and the model answers", %{directory: directory} do
    client = open(directory)
    {client, before_request, request_id} = ask(client)

    assert types(before_request) == [
             "prompt.accepted",
             "tool_call.updated",
             "permission.requested"
           ]

    assert Enum.at(before_request, 1)["payload"]["status"] == "pending"
    refute_received {:tool_called, _name, _arguments, _options}

    client = respond(client, request_id, "allow_once")
    {_client, after_answer} = events_until(client, "text.delta")

    assert types(after_answer) ==
             ["permission.resolved", "tool_call.updated", "tool_call.updated", "text.delta"]

    assert after_answer |> Enum.slice(1, 2) |> Enum.map(& &1["payload"]["status"]) ==
             ["in_progress", "completed"]

    assert List.last(after_answer)["payload"]["text"] == "done"
    assert_received {:tool_called, "files__write_file", %{"path" => "/a"}, _options}
    assert %{content: "written", is_error: false} = result_seen_by_model()
  end

  test "a rejected call never reaches the tool and the model is told", %{directory: directory} do
    client = open(directory)
    {client, _events, request_id} = ask(client)

    client = respond(client, request_id, "reject_once")
    {_client, after_answer} = events_until(client, "text.delta")

    assert hd(after_answer)["payload"]["outcome"] == "rejected"
    assert after_answer |> Enum.at(1) |> get_in(["payload", "status"]) == "failed"
    refute_received {:tool_called, _name, _arguments, _options}

    assert %{content: "The person rejected this tool call.", is_error: true} =
             result_seen_by_model()
  end

  test "a request nobody answers expires and the model is told", %{directory: directory} do
    client = open(directory, permission_timeout_ms: 150)
    {client, _events, _request_id} = ask(client)

    {_client, after_deadline} = events_until(client, "text.delta")

    assert hd(after_deadline)["payload"]["outcome"] == "expired"
    refute_received {:tool_called, _name, _arguments, _options}

    assert %{content: "The person did not answer in time, so this tool call was not run."} =
             result_seen_by_model()
  end
end
