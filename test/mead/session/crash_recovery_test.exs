defmodule Mead.Session.CrashRecoveryTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Turn
  alias Mead.Test.ScriptedHandler

  @moduletag timeout: 10_000
  @moduletag :capture_log

  defp start_session! do
    {:ok, session_id} = Mead.start_session(handler: ScriptedHandler, turn_timeout: 5_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  # Kills the session's server and waits for the supervisor to bring up a replacement. The
  # replacement registers its name before `init/1` runs, so `:sys.get_state/1` is used to wait
  # until it has finished initializing.
  defp kill_server_and_await_replacement(session_id) do
    old_pid = Session.whereis(session_id, :server)
    Process.exit(old_pid, :kill)

    new_pid =
      wait_until(fn ->
        candidate = Session.whereis(session_id, :server)
        candidate != old_pid and candidate
      end)

    :sys.get_state(new_pid)
    new_pid
  end

  test "a server killed mid-turn comes back with the same id and its history, and the turn is interrupted" do
    session_id = start_session!()
    assert Mead.submit_turn(session_id, {:echo, "before"}) == {:ok, "before"}
    old_server_pid = Session.whereis(session_id, :server)
    test_pid = self()

    caller = Task.async(fn -> Mead.submit_turn(session_id, {:block, test_pid}) end)
    assert_receive {:handler_started, handler_pid}

    Process.exit(old_server_pid, :kill)

    assert Task.await(caller) == {:error, :session_crashed}

    new_server_pid =
      wait_until(fn ->
        candidate = Session.whereis(session_id, :server)
        candidate != old_server_pid and candidate
      end)

    :sys.get_state(new_server_pid)

    assert {:ok,
            [
              %Turn{input: {:echo, "before"}, status: :ok, output: "before"},
              %Turn{input: {:block, _}, status: :interrupted}
            ]} = Mead.history(session_id)

    assert Mead.submit_turn(session_id, {:echo, "after"}) == {:ok, "after"}
    wait_until(fn -> not Process.alive?(handler_pid) end)
  end

  test "killing an idle server loses nothing" do
    session_id = start_session!()
    assert Mead.submit_turn(session_id, {:echo, "kept"}) == {:ok, "kept"}

    kill_server_and_await_replacement(session_id)

    assert {:ok, [%Turn{input: {:echo, "kept"}, status: :ok}]} = Mead.history(session_id)
  end

  test "killing one session's server leaves its neighbour untouched" do
    session_id = start_session!()
    neighbour_id = start_session!()

    neighbour_pids =
      for role <- [:supervisor, :history, :server], do: Session.whereis(neighbour_id, role)

    kill_server_and_await_replacement(session_id)

    assert for(role <- [:supervisor, :history, :server], do: Session.whereis(neighbour_id, role)) ==
             neighbour_pids

    assert Mead.submit_turn(neighbour_id, {:echo, "unaffected"}) == {:ok, "unaffected"}
  end

  test "a crash loop removes that conversation only" do
    session_id = start_session!()
    neighbour_id = start_session!()
    neighbour_server_pid = Session.whereis(neighbour_id, :server)

    # Three restarts are allowed within five seconds; the fourth crash takes the pair down.
    for _attempt <- 1..3, do: kill_server_and_await_replacement(session_id)
    Process.exit(Session.whereis(session_id, :server), :kill)

    wait_until(fn ->
      Enum.all?([:supervisor, :history, :server], &(Session.whereis(session_id, &1) == nil))
    end)

    # A transient pair that shut down on purpose must not be brought back.
    Process.sleep(100)
    assert Session.whereis(session_id, :supervisor) == nil
    assert Mead.history(session_id) == {:error, :not_found}
    assert Mead.submit_turn(session_id, {:echo, "gone"}) == {:error, :not_found}

    assert Session.whereis(neighbour_id, :server) == neighbour_server_pid
    assert Mead.submit_turn(neighbour_id, {:echo, "alive"}) == {:ok, "alive"}
  end
end
