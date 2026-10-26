defmodule Mead.Deck.ChannelTest do
  # Changes the global :storage setting in one test, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Deck.Channel
  alias Mead.Deck.ChannelSupervisor
  alias Mead.Deck.Configuration
  alias Mead.Session.Pool

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    {:ok, session_id} = Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 5_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)

    {:ok, configuration} = Configuration.load(token: "deck-channel-test-token")
    {:ok, channel} = ensure(session_id, configuration, directory)

    %{
      session_id: session_id,
      channel: channel,
      configuration: configuration,
      directory: directory
    }
  end

  defp ensure(session_id, configuration, directory) do
    ChannelSupervisor.ensure(session_id,
      configuration: configuration,
      storage_directory: directory
    )
  end

  defp prompt(channel, text, id \\ nil, socket \\ self()) do
    id = id || "message-#{System.unique_integer([:positive])}"
    Channel.client_message(channel, socket, {:prompt_send, %{client_message_id: id, text: text}})
  end

  defp next_event(timeout \\ 5_000) do
    assert_receive {:deck_event, binary}, timeout
    JSON.decode!(binary)
  end

  defp collect(count), do: for(_index <- 1..count, do: next_event())

  defp types(events), do: Enum.map(events, & &1["type"])
  defp sequences(events), do: Enum.map(events, & &1["sequence"])

  # A stand-in for a socket process, tagged so one test can tell several sockets apart.
  defp relay(label) do
    test = self()

    spawn(fn ->
      forward = fn forward ->
        receive do
          {:deck_event, binary} ->
            send(test, {:from, label, JSON.decode!(binary)})
            forward.(forward)
        end
      end

      forward.(forward)
    end)
  end

  defp attach(channel) do
    :ok = Channel.resume(channel, self(), 0)
    snapshot = next_event()
    assert snapshot["type"] == "session.snapshot"
    snapshot
  end

  test "ensure returns the same channel for the same session", context do
    assert {:ok, same} = ensure(context.session_id, context.configuration, context.directory)
    assert same == context.channel
  end

  test "the first connection gets an unsequenced snapshot", %{
    channel: channel,
    session_id: session_id
  } do
    :ok = Channel.resume(channel, self(), 0)
    snapshot = next_event()

    assert snapshot["type"] == "session.snapshot"
    assert snapshot["sequence"] == nil
    assert snapshot["session_id"] == session_id

    assert snapshot["payload"] == %{
             "protocol_version" => 1,
             "current_sequence" => 0,
             "permission_policy_level" => "ask_for_risky"
           }

    refute_receive {:deck_event, _}, 100
    assert Channel.policy_level(channel) == :ask_for_risky
  end

  test "a prompt is accepted, answered, and followed by the token metrics", %{channel: channel} do
    attach(channel)
    prompt(channel, "echo hi", "m-1")

    events = collect(4)

    assert types(events) == ["prompt.accepted", "text.delta", "metric.updated", "metric.updated"]
    assert sequences(events) == [1, 2, 3, 4]

    [accepted, delta, tokens_in, tokens_out] = events
    assert accepted["payload"] == %{"client_message_id" => "m-1", "text" => "echo hi"}
    assert delta["payload"] == %{"turn_id" => "turn-1", "text" => "hi"}
    assert tokens_in["payload"]["key"] == "tokens_in"
    assert tokens_in["payload"]["unit"] == "tokens"
    assert tokens_out["payload"]["key"] == "tokens_out"
    assert is_binary(accepted["occurred_at"])
  end

  test "sequences increase by one without gaps across turns", %{channel: channel} do
    attach(channel)
    for index <- 1..3, do: prompt(channel, "echo number #{index}")

    events = collect(12)
    assert sequences(events) == Enum.to_list(1..12)
  end

  test "a repeated client_message_id replays its acceptance and starts no turn", context do
    %{channel: channel, session_id: session_id} = context
    attach(channel)
    prompt(channel, "echo hi", "same")
    collect(4)

    prompt(channel, "echo hi", "same")
    replay = next_event()

    assert replay["type"] == "prompt.accepted"
    assert replay["sequence"] == 1
    refute_receive {:deck_event, _}, 200
    assert {:ok, [_only_turn]} = Mead.history(session_id)
  end

  test "resume replays only what was missed, in order, with the original numbers", %{
    channel: channel
  } do
    attach(channel)
    prompt(channel, "echo hi")
    collect(4)

    :ok = Channel.resume(channel, self(), 2)
    events = collect(3)
    assert types(events) == ["session.snapshot", "metric.updated", "metric.updated"]
    assert sequences(events) == [nil, 3, 4]
    refute_receive {:deck_event, _}, 100
  end

  test "a last_sequence in the future gets the snapshot only", %{channel: channel} do
    attach(channel)
    prompt(channel, "echo hi")
    collect(4)

    :ok = Channel.resume(channel, self(), 99)
    snapshot = next_event()
    assert snapshot["type"] == "session.snapshot"
    assert snapshot["payload"]["current_sequence"] == 4
    refute_receive {:deck_event, _}, 100
  end

  test "prompts from a socket that never resumed are ignored", %{channel: channel} do
    prompt(channel, "echo hi")
    refute_receive {:deck_event, _}, 200
  end

  test "a prompt sent during a turn is accepted at once and runs after it", context do
    %{channel: channel} = context
    attach(channel)
    prompt(channel, "block first")
    assert_receive {:handler_started, handler, "block first"}

    prompt(channel, "echo second")
    assert next_event()["type"] == "prompt.accepted"
    assert next_event()["type"] == "prompt.accepted"
    refute_receive {:deck_event, _}, 100

    send(handler, :release)
    events = collect(6)

    assert types(events) ==
             ~w(text.delta metric.updated metric.updated text.delta metric.updated metric.updated)

    assert sequences(events) == [3, 4, 5, 6, 7, 8]
    assert Enum.at(events, 0)["payload"]["text"] == "released block first"
    assert Enum.at(events, 3)["payload"]["text"] == "second"
  end

  test "a prompt over the queue limit is dropped without any event", context do
    {:ok, configuration} = Configuration.load(token: "deck-channel-test-token", queue_limit: 2)
    {:ok, session_id} = Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 5_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)
    {:ok, channel} = ensure(session_id, configuration, context.directory)

    attach(channel)
    prompt(channel, "block run")
    assert_receive {:handler_started, handler, _input}

    for text <- ["echo one", "echo two", "echo three"], do: prompt(channel, text)
    accepted = collect(3)
    assert types(accepted) == ["prompt.accepted", "prompt.accepted", "prompt.accepted"]
    refute_receive {:deck_event, _}, 150

    send(handler, :release)
    events = collect(9)
    texts = for %{"type" => "text.delta", "payload" => %{"text" => text}} <- events, do: text
    assert texts == ["released block run", "one", "two"]
    refute_receive {:deck_event, _}, 150
  end

  test "two sessions never see each other's events", context do
    {:ok, other_id} = Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 5_000)
    on_exit(fn -> Mead.stop_session(other_id) end)
    {:ok, other} = ensure(other_id, context.configuration, context.directory)

    first_socket = relay(:first)
    second_socket = relay(:second)
    :ok = Channel.resume(context.channel, first_socket, 0)
    :ok = Channel.resume(other, second_socket, 0)
    assert_receive {:from, :first, %{"type" => "session.snapshot"}}
    assert_receive {:from, :second, %{"type" => "session.snapshot"}}

    prompt(context.channel, "echo for first", "a", first_socket)
    prompt(other, "echo for second", "b", second_socket)

    for _event <- 1..8, do: assert_receive({:from, _label, _event})

    refute_receive {:from, _label, _event}, 100
  end

  test "a restarted channel continues the sequence from the log", context do
    %{channel: channel, session_id: session_id} = context
    attach(channel)
    prompt(channel, "echo hi")
    collect(4)

    :ok = ChannelSupervisor.stop(session_id)
    refute Process.alive?(channel)
    {:ok, restarted} = ensure(session_id, context.configuration, context.directory)
    refute restarted == channel

    :ok = Channel.resume(restarted, self(), 0)
    events = collect(5)
    assert sequences(events) == [nil, 1, 2, 3, 4]
    assert hd(events)["payload"]["current_sequence"] == 4

    prompt(restarted, "echo again", "again")
    assert next_event()["sequence"] == 5
  end

  test "a duplicate id is still recognised after a restart", context do
    %{channel: channel, session_id: session_id} = context
    attach(channel)
    prompt(channel, "echo hi", "durable")
    collect(4)

    :ok = ChannelSupervisor.stop(session_id)
    {:ok, restarted} = ensure(session_id, context.configuration, context.directory)
    :ok = Channel.resume(restarted, self(), 4)
    assert next_event()["type"] == "session.snapshot"

    prompt(restarted, "echo hi", "durable")
    assert next_event()["sequence"] == 1
    refute_receive {:deck_event, _}, 200
    assert {:ok, [_only_turn]} = Mead.history(session_id)
  end

  test "a socket that dies is forgotten and the channel carries on", %{channel: channel} do
    dying = relay(:dying)
    :ok = Channel.resume(channel, dying, 0)
    assert_receive {:from, :dying, %{"type" => "session.snapshot"}}

    Process.exit(dying, :kill)
    wait_until(fn -> :sys.get_state(channel).sockets == %{} end)

    attach(channel)
    prompt(channel, "echo alive")
    assert types(collect(4)) == ~w(prompt.accepted text.delta metric.updated metric.updated)
  end

  test "a failed turn emits no text, says it failed and the channel keeps working",
       %{channel: channel} do
    attach(channel)

    prompt(channel, "error")
    assert types(collect(4)) == ~w(prompt.accepted turn.failed metric.updated metric.updated)

    for text <- ["binary", "empty"] do
      prompt(channel, text)

      assert types(collect(3)) == ~w(prompt.accepted metric.updated metric.updated)
    end

    prompt(channel, "echo recovered")
    assert "text.delta" in types(collect(4))
  end

  test "the metrics are the ledger totals of the session", %{channel: channel} do
    attach(channel)
    prompt(channel, "telemetry 5 7")
    [_accepted, _delta, tokens_in, tokens_out] = collect(4)
    assert tokens_in["payload"]["value"] == 5
    assert tokens_out["payload"]["value"] == 7

    prompt(channel, "telemetry 1 2")
    [_accepted, _delta, tokens_in, tokens_out] = collect(4)
    assert tokens_in["payload"]["value"] == 6
    assert tokens_out["payload"]["value"] == 9
  end

  test "the channel stops when its session stops", %{channel: channel, session_id: session_id} do
    reference = Process.monitor(channel)
    :ok = Pool.stop_session(session_id)

    assert_receive {:DOWN, ^reference, :process, ^channel, {:shutdown, :session_gone}}
  end

  test "a channel cannot start for a session that does not run", context do
    assert {:error, :session_not_found} =
             ensure(Mead.UUID.generate(), context.configuration, context.directory)
  end

  test "a log that cannot be written stops the channel before anything is sent", context do
    %{channel: channel, directory: directory} = context
    attach(channel)
    on_exit(fn -> File.chmod(directory, 0o700) end)
    File.chmod!(directory, 0o500)

    reference = Process.monitor(channel)
    prompt(channel, "echo hi")

    assert_receive {:DOWN, ^reference, :process, ^channel, {:shutdown, {:log_failed, _reason}}}
    refute_receive {:deck_event, _}, 100
  end

  describe "with a storage directory" do
    setup %{directory: directory} do
      previous = Application.get_env(:mead, :storage)
      Application.put_env(:mead, :storage, directory: directory)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:mead, :storage)
          value -> Application.put_env(:mead, :storage, value)
        end
      end)

      {:ok, session_id} = Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 5_000)
      {:ok, channel} = ChannelSupervisor.ensure(session_id, configuration: loaded_configuration())
      %{stored_id: session_id, stored_channel: channel}
    end

    defp loaded_configuration do
      {:ok, configuration} = Configuration.load(token: "deck-channel-test-token")
      configuration
    end

    test "stop keeps the events and delete removes them with the conversation", context do
      %{stored_id: session_id, stored_channel: channel, directory: directory} = context
      attach(channel)
      prompt(channel, "echo kept")
      collect(4)

      events_file = Path.join(directory, session_id <> ".events")
      log_file = Path.join(directory, session_id <> ".log")
      assert File.exists?(events_file)

      reference = Process.monitor(channel)
      :ok = Mead.stop_session(session_id)
      assert_receive {:DOWN, ^reference, :process, ^channel, _reason}
      assert File.exists?(events_file)

      assert :ok = Mead.delete_session(session_id)
      refute File.exists?(events_file)
      refute File.exists?(log_file)
    end
  end
end
