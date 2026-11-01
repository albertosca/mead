defmodule Mead.Deck.DurableChannelTest do
  # A deck turn outlives the processes around it: a session server that restarts mid-turn, and a
  # channel that dies and starts again, both end with the turn's outcome on the deck instead of an
  # interruption.
  use ExUnit.Case, async: false

  alias Mead.Deck.EventLog
  alias Mead.Session
  alias Mead.Test.DeckServer
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: directory} do
    previous_storage = Application.get_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous_storage do
        nil -> Application.delete_env(:mead, :storage)
        value -> Application.put_env(:mead, :storage, value)
      end
    end)

    %{directory: directory}
  end

  defp start_server(directory),
    do:
      DeckServer.start(directory, [],
        session_options: [handler: Mead.Test.DurableDeckHandler, turn_timeout: 10_000]
      )

  defp open_new(server) do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)
    {connect(server, ticket), session_id}
  end

  defp connect(server, ticket) do
    client = DeckServer.open(server, ticket, 0)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    client
  end

  defp reconnect(server, session_id) do
    %{"ticket" => ticket} = DeckServer.ticket(server, session_id)
    connect(server, ticket)
  end

  defp channel_of(session_id) do
    [{pid, _value}] = Registry.lookup(Mead.Registry, {:deck, session_id})
    pid
  end

  defp kill_and_wait(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  # Every sequenced event up to and including the closing metric of `turn_id`.
  defp events_until_end(client, turn_id, collected \\ []) do
    {client, envelope} = WebSocketClient.receive_json(client, 15_000)
    assert is_map(envelope), "expected an event, got #{inspect(envelope)}"

    cond do
      envelope["type"] == "heartbeat" ->
        events_until_end(client, turn_id, collected)

      envelope["type"] == "metric.updated" and envelope["payload"]["key"] == "tokens_out" and
          envelope["payload"]["turn_id"] == turn_id ->
        {client, collected ++ [envelope]}

      true ->
        events_until_end(client, turn_id, collected ++ [envelope])
    end
  end

  defp text_events(events) do
    for %{"type" => type, "payload" => payload} <- events,
        type in ["text.delta", "text.reset", "turn.failed"],
        do: {type, payload["text"] || payload["reason"]}
  end

  defp kill_server_mid_turn(directory, prompt) do
    server = start_server(directory)
    {client, session_id} = open_new(server)
    channel = channel_of(session_id)

    _client = DeckServer.send_prompt(client, prompt)
    assert_receive {:handler_started, _handler, ^prompt}, 5_000

    kill_and_wait(Session.whereis(session_id, :server))
    {_client, events} = events_until_end(client, "turn-1")

    {session_id, channel, events}
  end

  test "a server killed mid-turn leaves the channel up and sends only the rest of the text",
       %{directory: directory} do
    {session_id, channel, events} = kill_server_mid_turn(directory, "stream Hel|Hello")

    assert text_events(events) == [{"text.delta", "Hel"}, {"text.delta", "lo"}]
    assert channel_of(session_id) == channel

    assert {:ok, [%{status: :ok, client_turn_id: "turn-1", output: "Hello"}]} =
             Mead.history(session_id)
  end

  test "an answer that does not continue the streamed text resets it and sends the whole text",
       %{directory: directory} do
    {_session_id, _channel, events} = kill_server_mid_turn(directory, "stream Bye|Hello")

    assert text_events(events) == [
             {"text.delta", "Bye"},
             {"text.reset", nil},
             {"text.delta", "Hello"}
           ]

    reset = Enum.find(events, &(&1["type"] == "text.reset"))
    assert reset["payload"] == %{"turn_id" => "turn-1"}
  end

  test "a restarted channel resubmits its unfinished turn and shows the outcome",
       %{directory: directory} do
    server = start_server(directory)
    {client, session_id} = open_new(server)

    _client = DeckServer.send_prompt(client, "stream Hel|Hello")
    assert_receive {:handler_started, handler, "stream Hel|Hello"}, 5_000

    kill_and_wait(channel_of(session_id))
    client = reconnect(server, session_id)

    # The new channel joins the running turn before it ends.
    Mead.TestHelpers.wait_until(fn ->
      match?({:ok, _interaction, false}, Session.Server.attached_interaction(session_id)) and
        attached_channel(session_id) == channel_of(session_id)
    end)

    send(handler, :release)
    {_client, events} = events_until_end(client, "turn-1")

    assert text_events(events) == [{"text.delta", "Hel"}, {"text.delta", "lo"}]
  end

  defp attached_channel(session_id) do
    {:ok, {_module, %{channel: channel}}, _streaming} =
      Session.Server.attached_interaction(session_id)

    channel
  end

  test "a restarted channel reports a prompt the session never recorded as interrupted",
       %{directory: directory} do
    server = start_server(directory)
    %{"session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)

    # A prompt the log accepted but whose turn never reached the session.
    {:ok, log} = EventLog.open(directory, session_id)
    sequence = EventLog.last_sequence(log) + 1

    {:ok, _log} =
      EventLog.append(log, %{
        "sequence" => sequence,
        "type" => "prompt.accepted",
        "payload" => %{"client_message_id" => "lost", "text" => "never sent"}
      })

    client = reconnect(server, session_id)
    {_client, events} = events_until_end(client, "turn-#{sequence}")

    assert text_events(events) == [{"turn.failed", "interrupted"}]
  end

  test "without storage the key carries an epoch drawn when the channel starts" do
    Application.delete_env(:mead, :storage)
    server = start_server(nil)
    {client, session_id} = open_new(server)

    _client = DeckServer.send_prompt(client, "hi")
    {_client, _events} = events_until_end(client, "turn-1")

    assert {:ok, [%{client_turn_id: key, output: "reply to: hi"}]} = Mead.history(session_id)
    assert key =~ ~r/^turn-1-[A-Za-z0-9_-]{8,}$/
  end
end
