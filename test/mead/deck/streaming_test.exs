defmodule Mead.Deck.StreamingTest do
  # The real listener, the real WebSocket, the real channel and the real router; only the model is
  # scripted.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
  alias Mead.Test.StreamingProvider
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir

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

  defp script_turn(provider, text, provider_options \\ []) do
    {:ok, script} = Agent.start_link(fn -> [FakeProvider.text_step(text)] end)
    slot = {provider, [test_pid: self(), script: script] ++ provider_options}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: slot, cloud: slot],
      hub: [
        test_pid: self(),
        tools: [%{name: "files__read_file", description: "Read", input_schema: %{}}],
        results: %{}
      ]
    })
  end

  defp open(directory) do
    server =
      DeckServer.start(directory, [],
        # Five thousand fragments are five thousand file writes; a slow disk must not end the turn.
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 60_000]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    {client, session_id}
  end

  # Every sequenced event up to and including the last metric of the turn.
  defp events_until_turn_end(client, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 5_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    cond do
      envelope["type"] == "heartbeat" ->
        events_until_turn_end(client, collected)

      envelope["type"] == "metric.updated" and envelope["payload"]["key"] == "tokens_out" ->
        {client, collected ++ [envelope]}

      true ->
        events_until_turn_end(client, collected ++ [envelope])
    end
  end

  defp delta_texts(events),
    do: for(%{"type" => "text.delta", "payload" => %{"text" => text}} <- events, do: text)

  defp assert_gapless(events) do
    sequences = Enum.map(events, & &1["sequence"])
    assert sequences == Enum.to_list(hd(sequences)..List.last(sequences))
  end

  test "fragments arrive in order and the whole text is not sent again", %{directory: directory} do
    script_turn(StreamingProvider, "streamed answer")
    {client, session_id} = open(directory)

    client = DeckServer.send_prompt(client, "go")
    {_client, events} = events_until_turn_end(client)

    assert delta_texts(events) == ["str", "eam", "ed ", "ans", "wer"]
    assert {:ok, history} = Mead.history(session_id)
    assert List.last(history).output == "streamed answer"
    assert_gapless(events)
  end

  test "a provider that cannot stream still sends one delta", %{directory: directory} do
    script_turn(FakeProvider, "whole answer")
    {client, _session_id} = open(directory)

    client = DeckServer.send_prompt(client, "go")
    {_client, events} = events_until_turn_end(client)

    assert delta_texts(events) == ["whole answer"]
  end

  test "a stream that fails midway keeps its fragments, fails the turn and sends no final text",
       %{directory: directory} do
    script_turn(StreamingProvider, "fake reply", fail_after: 2)
    {client, session_id} = open(directory)

    client = DeckServer.send_prompt(client, "go")
    {_client, events} = events_until_turn_end(client)

    assert delta_texts(events) == ["fak", "e r"]
    assert {:ok, history} = Mead.history(session_id)
    assert %{status: :failed, output: :timeout} = List.last(history)
    refute Enum.any?(history, &(&1.output == "fake reply"))
  end

  test "five thousand fragments keep the sequence gapless and the log readable",
       %{directory: directory} do
    text = String.duplicate("x", 5_000)
    script_turn(StreamingProvider, text, fragment_size: 1)
    {client, session_id} = open(directory)

    client = DeckServer.send_prompt(client, "go")
    {client, events} = events_until_turn_end(client)

    assert length(delta_texts(events)) == 5_000
    assert_gapless(events)
    WebSocketClient.close(client)

    {reconnected, _session_id} = reconnect(directory, session_id)
    {_reconnected, replayed} = replay_all(reconnected)
    assert length(delta_texts(replayed)) == 5_000
  end

  defp reconnect(directory, session_id) do
    server =
      DeckServer.start(directory, [],
        session_options: [handler: Mead.Test.ToolHandler, turn_timeout: 10_000]
      )

    %{"ticket" => ticket} = DeckServer.ticket(server, session_id)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    {client, session_id}
  end

  defp replay_all(client, collected \\ []) do
    case WebSocketClient.receive_json(client, 500) do
      {client, :timeout} -> {client, collected}
      {client, %{"type" => "heartbeat"}} -> replay_all(client, collected)
      {client, envelope} -> replay_all(client, collected ++ [envelope])
    end
  end
end
