defmodule Mead.Session.TurnFailuresTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Turn
  alias Mead.Test.ScriptedHandler

  # A server that never answers would hang the caller forever, so fail fast instead.
  @moduletag timeout: 5_000
  @moduletag :capture_log

  setup do
    {:ok, session_id} = Mead.start_session(handler: ScriptedHandler, turn_timeout: 200)
    on_exit(fn -> Mead.stop_session(session_id) end)

    %{session_id: session_id, server_pid: Session.whereis(session_id, :server)}
  end

  test "a handler that raises fails the turn and leaves the server alone", context do
    %{session_id: session_id, server_pid: server_pid} = context

    assert Mead.submit_turn(session_id, :raise) == {:error, :failed}
    assert Session.whereis(session_id, :server) == server_pid
    assert Mead.submit_turn(session_id, {:echo, "still here"}) == {:ok, "still here"}

    assert {:ok, [%Turn{status: :failed}, %Turn{status: :ok, output: "still here"}]} =
             Mead.history(session_id)
  end

  test "a handler that exits fails the turn and leaves the server alone", context do
    %{session_id: session_id, server_pid: server_pid} = context

    assert Mead.submit_turn(session_id, :exit) == {:error, :failed}
    assert Session.whereis(session_id, :server) == server_pid
    assert {:ok, [%Turn{status: :failed, output: :scripted_exit}]} = Mead.history(session_id)
  end

  test "a handler that returns an error tuple fails the turn and keeps the reason", context do
    %{session_id: session_id} = context

    assert Mead.submit_turn(session_id, {:error, :quota_exceeded}) == {:error, :failed}
    assert {:ok, [%Turn{status: :failed, output: :quota_exceeded}]} = Mead.history(session_id)
  end

  test "a handler that returns anything else fails the turn", context do
    %{session_id: session_id} = context

    assert Mead.submit_turn(session_id, :bad_return) == {:error, :failed}

    assert {:ok, [%Turn{status: :failed, output: {:bad_return, :unexpected}}]} =
             Mead.history(session_id)
  end

  test "a handler that outlives the timeout is killed and the turn times out", context do
    %{session_id: session_id, server_pid: server_pid} = context

    assert Mead.submit_turn(session_id, {:block, self()}) == {:error, :timeout}
    assert_received {:handler_started, handler_pid}

    wait_until(fn -> not Process.alive?(handler_pid) end)
    assert Session.whereis(session_id, :server) == server_pid
    assert {:ok, [%Turn{status: :timeout}]} = Mead.history(session_id)
    assert Mead.submit_turn(session_id, {:echo, "recovered"}) == {:ok, "recovered"}
  end

  test "a second turn while one is running is refused", context do
    %{session_id: session_id} = context
    test_pid = self()

    first_turn = Task.async(fn -> Mead.submit_turn(session_id, {:block, test_pid}) end)
    assert_receive {:handler_started, handler_pid}

    assert Mead.submit_turn(session_id, {:echo, "too soon"}) == {:error, :turn_in_progress}

    send(handler_pid, :release)
    assert Task.await(first_turn) == {:ok, :released}
    assert {:ok, [%Turn{input: {:block, _}, status: :ok}]} = Mead.history(session_id)
  end

  test "a caller that dies mid-turn does not wedge the session", context do
    %{session_id: session_id} = context
    test_pid = self()

    {:ok, caller_pid} =
      Task.start(fn -> Mead.submit_turn(session_id, {:block, test_pid}) end)

    assert_receive {:handler_started, handler_pid}

    Process.exit(caller_pid, :kill)
    send(handler_pid, :release)

    wait_until(fn -> match?({:ok, [%Turn{status: :ok}]}, Mead.history(session_id)) end)
    assert Mead.submit_turn(session_id, {:echo, "next"}) == {:ok, "next"}
  end

  test "a handler that dies on its own as the timer fires is a failure, not a timeout", context do
    %{session_id: session_id, server_pid: server_pid} = context
    test_pid = self()

    caller = Task.async(fn -> Mead.submit_turn(session_id, {:block, test_pid}) end)
    assert_receive {:handler_started, handler_pid}

    # Queue the timer message ahead of the task's own death signals, then let the server go.
    :sys.suspend(server_pid)
    %{running: %{task: %Task{ref: reference}}} = :sys.get_state(server_pid)
    send(server_pid, {:turn_timeout, reference})
    Process.exit(handler_pid, :scripted_death)
    :sys.resume(server_pid)

    assert Task.await(caller) == {:error, :failed}
    assert {:ok, [%Turn{status: :failed, output: :scripted_death}]} = Mead.history(session_id)
  end
end
