defmodule Mead.Session.ClockTest do
  use ExUnit.Case, async: true

  alias Mead.Session
  alias Mead.Session.Server

  @moduletag timeout: 30_000
  @moduletag :capture_log

  defp start_session(turn_timeout) do
    {:ok, session_id} =
      Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: turn_timeout)

    on_exit(fn -> Mead.stop_session(session_id) end)
    Registry.register(Mead.Registry, {:deck_test_notify, session_id}, nil)
    session_id
  end

  # Starts a turn that blocks until released and waits until the handler is running.
  defp start_blocked_turn(session_id) do
    turn = Task.async(fn -> Mead.submit_turn(session_id, "block clock") end)
    assert_receive {:handler_started, handler, "block clock"}, 2_000
    {turn, handler}
  end

  test "pausing the clock waits for a busy session server instead of giving up after five seconds" do
    session_id = start_session(10_000)
    server = Mead.Session.whereis(session_id, :server)
    :ok = :sys.suspend(server)

    task = Task.async(fn -> Server.pause_clock(session_id) end)
    assert Task.yield(task, 5_500) == nil

    :ok = :sys.resume(server)
    assert Task.await(task) == :ok
  end

  test "a paused turn does not time out and completes once released" do
    session_id = start_session(200)
    {turn, handler} = start_blocked_turn(session_id)

    assert :ok = Server.pause_clock(session_id)
    Process.sleep(600)
    send(handler, :release)
    assert :ok = Server.resume_clock(session_id)

    assert {:ok, "released block clock"} = Task.await(turn)
  end

  test "the time that was left is honoured after the resume" do
    session_id = start_session(400)
    {turn, _handler} = start_blocked_turn(session_id)

    Process.sleep(250)
    assert :ok = Server.pause_clock(session_id)
    Process.sleep(300)
    resumed_at = System.monotonic_time(:millisecond)
    assert :ok = Server.resume_clock(session_id)

    assert {:error, :timeout} = Task.await(turn)
    elapsed = System.monotonic_time(:millisecond) - resumed_at
    assert elapsed in 60..320, "timed out #{elapsed} ms after the resume"
  end

  test "pauses nest: only the last resume restarts the clock" do
    session_id = start_session(150)
    {turn, _handler} = start_blocked_turn(session_id)

    assert :ok = Server.pause_clock(session_id)
    assert :ok = Server.pause_clock(session_id)
    assert :ok = Server.resume_clock(session_id)

    assert Task.yield(turn, 400) == nil
    assert :ok = Server.resume_clock(session_id)
    assert {:error, :timeout} = Task.await(turn)
  end

  test "a resume without a pause changes nothing" do
    session_id = start_session(250)
    {turn, _handler} = start_blocked_turn(session_id)

    assert :ok = Server.resume_clock(session_id)
    assert {:error, :timeout} = Task.await(turn)
  end

  test "a pause with no turn running does not leak into the next turn" do
    session_id = start_session(200)

    assert :ok = Server.pause_clock(session_id)
    {turn, _handler} = start_blocked_turn(session_id)

    assert {:error, :timeout} = Task.await(turn)
  end

  test "an unknown session is not found" do
    unknown = Mead.UUID.generate()
    assert {:error, :not_found} = Server.pause_clock(unknown)
    assert {:error, :not_found} = Server.resume_clock(unknown)
  end

  test "a timeout message from a replaced timer is ignored" do
    session_id = start_session(10_000)
    {turn, handler} = start_blocked_turn(session_id)
    server = Session.whereis(session_id, :server)

    assert :ok = Server.pause_clock(session_id)
    assert :ok = Server.resume_clock(session_id)

    %{running: %{task: %Task{ref: reference}, generation: generation}} = :sys.get_state(server)
    send(server, {:turn_timeout, reference, generation - 1})
    _ = :sys.get_state(server)

    assert Process.alive?(handler)
    send(handler, :release)
    assert {:ok, _output} = Task.await(turn)
  end
end
