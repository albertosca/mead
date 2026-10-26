defmodule Mead.Deck.RecoveryTest do
  # What a new channel makes of the log an earlier one left behind: queued prompts still run, the
  # turn that was running is reported as interrupted, and tool cards left open are closed.
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

  defp open_new(server) do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    {connect(server, ticket, 0), session_id}
  end

  defp connect(server, ticket, last_sequence) do
    client = DeckServer.open(server, ticket, last_sequence)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    client
  end

  defp reconnect(server, session_id) do
    %{"ticket" => ticket} = DeckServer.ticket(server, session_id)
    connect(server, ticket, 0)
  end

  defp channel_of(session_id) do
    [{pid, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
    pid
  end

  defp stop_and_wait(pid, how) do
    monitor = Process.monitor(pid)
    Process.exit(pid, how)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  # Every sequenced event until `done` is true for one of them.
  defp events_until(client, done, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 5_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    cond do
      envelope["type"] == "heartbeat" -> events_until(client, done, collected)
      done.(envelope) -> {client, collected ++ [envelope]}
      true -> events_until(client, done, collected ++ [envelope])
    end
  end

  defp tokens_out_of?(turn_id),
    do: fn envelope ->
      envelope["type"] == "metric.updated" and envelope["payload"]["key"] == "tokens_out" and
        envelope["payload"]["turn_id"] == turn_id
    end

  test "a prompt that was queued behind a running turn runs after the session restarts",
       %{directory: directory} do
    server = DeckServer.start(directory, [], session_options: [handler: Mead.Test.DeckHandler])
    {client, session_id} = open_new(server)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)

    client = DeckServer.send_prompt(client, "block first")
    assert_receive {:handler_started, handler, "block first"}, 2_000
    _client = DeckServer.send_prompt(client, "echo second")

    {_client, _accepted} =
      events_until(
        client,
        &(&1["type"] == "prompt.accepted" and &1["payload"]["text"] == "echo second")
      )

    channel = channel_of(session_id)
    stop_and_wait(channel, :kill)

    # The turn belongs to the session, not to the channel: it ends by itself once released.
    send(handler, :release)

    Mead.TestHelpers.wait_until(fn ->
      match?({:ok, [%{status: :ok}]}, Mead.history(session_id))
    end)

    client = reconnect(server, session_id)
    {_client, events} = events_until(client, tokens_out_of?("turn-2"))

    failed = Enum.find(events, &(&1["type"] == "turn.failed"))
    assert failed["payload"] == %{"turn_id" => "turn-1", "reason" => "interrupted"}

    texts = for %{"type" => "text.delta", "payload" => %{"text" => text}} <- events, do: text
    assert texts == ["second"]
  end

  test "a tool card left open by a dead channel is closed as failed", %{directory: directory} do
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
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 10_000]
      )

    {client, session_id} = open_new(server)
    client = DeckServer.send_prompt(client, "read the file")

    {_client, _events} =
      events_until(
        client,
        &(&1["type"] == "tool_call.updated" and &1["payload"]["status"] == "in_progress")
      )

    stop_and_wait(channel_of(session_id), :kill)

    client = reconnect(server, session_id)
    {_client, events} = events_until(client, tokens_out_of?("turn-1"))

    statuses =
      for %{"type" => "tool_call.updated", "payload" => payload} <- events, do: payload["status"]

    assert statuses == ["pending", "in_progress", "failed"]
  end
end
