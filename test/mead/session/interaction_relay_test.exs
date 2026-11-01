defmodule Mead.Session.InteractionRelayTest do
  # Sets the global :storage and :recovery settings, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.InteractionRelay
  alias Mead.Session.Server
  alias Mead.Test.{FakeInteraction, RelayHandler}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: directory} do
    previous = for key <- [:storage, :recovery], do: {key, Application.fetch_env(:mead, key)}
    Application.put_env(:mead, :storage, directory: directory)
    Application.put_env(:mead, :recovery, interaction_grace: 100)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:mead, key, value)
          :error -> Application.delete_env(:mead, key)
        end
      end
    end)

    :ok
  end

  defp start_session!(turn_timeout \\ 30_000) do
    {:ok, session_id} = Mead.start_session(handler: RelayHandler, turn_timeout: turn_timeout)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  defp interaction(answers), do: {FakeInteraction, FakeInteraction.start(answers)}

  defp submit_async(session_id, input, options) do
    Task.async(fn -> Mead.submit_turn(session_id, input, options) end)
  end

  # Starts a keyed interactive turn, lets it block, and brings the session back as an orderly
  # shutdown would, so the turn continues with nobody attached.
  defp continue_unattended(session_id, actions) do
    input = {:relay, self(), [:block | actions]}

    caller =
      submit_async(session_id, input, client_turn_id: "key-1", interaction: interaction([]))

    assert_receive {:relay_blocked, _pid}
    :ok = Server.suspend(session_id)
    Task.shutdown(caller, :brutal_kill)

    supervisor = Session.whereis(session_id, :supervisor)
    :ok = DynamicSupervisor.terminate_child(Session.Pool, supervisor)
    wait_until(fn -> Session.whereis(session_id, :history) == nil end)
    flush_options()

    assert Mead.resume_session(session_id, handler: RelayHandler) == {:ok, session_id}
    input
  end

  defp flush_options do
    receive do
      {:relay_options, _interaction} -> flush_options()
    after
      0 -> :ok
    end
  end

  test "a submit hands the turn the relay, which forwards every callback" do
    session_id = start_session!()
    actions = [:permission, :tool_updated, :register_call, {:delta, "hi"}, :choice]
    input = {:relay, self(), actions}

    assert Mead.submit_turn(session_id, input, interaction: interaction([{:deny, :rejected}])) ==
             {:ok, "done"}

    assert_received {:relay_options, {InteractionRelay, %{session_id: ^session_id}}}
    assert_received {:request_permission, %{tool_call_id: "call-1"}}
    assert_received {:relay_answer, :permission, {:deny, :rejected}, false, _at}
    assert_received {:tool_updated, %{status: :pending}}
    assert_received {:register_call, "call-1", _pid}
    assert_received {:text_delta, "hi"}
    assert_received {:ask_choice, %{tool_call_id: "ask-1"}}
    assert_received {:relay_answer, :choice, {:error, :no_answer}, false, _at}
  end

  test "a turn submitted without an interaction gets none" do
    session_id = start_session!()
    assert Mead.submit_turn(session_id, {:relay, self(), []}) == {:ok, "done"}
    assert_received {:relay_options, nil}
  end

  test "a continued turn nobody attaches to waits one grace, then is denied at once" do
    session_id = start_session!()
    continue_unattended(session_id, [:permission, :permission, :choice, :tool_updated])

    assert_receive {:relay_options, {InteractionRelay, %{session_id: ^session_id}}}
    resumed_at = System.monotonic_time(:millisecond)
    assert_receive {:relay_answer, :permission, {:deny, :unattended}, true, first_at}, 2_000
    assert_receive {:relay_answer, :permission, {:deny, :unattended}, true, second_at}
    assert_receive {:relay_answer, :choice, {:error, :no_answer}, true, _at}
    assert_receive {:relay_answer, :tool_updated, :ok, true, _at}

    assert first_at - resumed_at >= 90
    assert second_at - first_at < 50
    refute_received {:request_permission, _request}
  end

  test "an interaction that joins during the grace is used, without the deltas" do
    Application.put_env(:mead, :recovery, interaction_grace: 10_000)
    session_id = start_session!()
    input = continue_unattended(session_id, [:permission, {:delta, "late"}])

    server = Session.whereis(session_id, :server)

    wait_until(fn ->
      match?(%{running: %{interaction_waiters: [_ | _]}}, :sys.get_state(server))
    end)

    joined =
      submit_async(session_id, input, client_turn_id: "key-1", interaction: interaction([:allow]))

    assert_receive {:request_permission, %{tool_call_id: "call-1"}}
    assert_receive {:relay_answer, :permission, :allow, true, _at}
    assert_receive {:relay_answer, {:delta, "late"}, :ok, true, _at}
    refute_received {:text_delta, "late"}
    assert Task.await(joined) == {:ok, "done"}
  end

  test "an attached interaction whose process is gone counts as none" do
    session_id = start_session!()
    {FakeInteraction, context} = gone = interaction([])
    caller = submit_async(session_id, {:relay, self(), [:block, :permission]}, interaction: gone)
    assert_receive {:relay_blocked, handler_pid}

    Agent.stop(context.script)
    send(handler_pid, :release)

    assert_receive {:relay_answer, :permission, {:deny, :unattended}, false, _at}, 2_000
    assert Task.await(caller) == {:ok, "done"}
    assert Server.attached_interaction(session_id) == :none
  end

  test "the grace wait does not count against the turn timeout" do
    Application.put_env(:mead, :recovery, interaction_grace: 300)
    session_id = start_session!(100)
    {FakeInteraction, context} = gone = interaction([])
    Agent.stop(context.script)

    assert Mead.submit_turn(session_id, {:relay, self(), [:permission]}, interaction: gone) ==
             {:ok, "done"}

    assert_received {:relay_answer, :permission, {:deny, :unattended}, false, _at}
  end
end
