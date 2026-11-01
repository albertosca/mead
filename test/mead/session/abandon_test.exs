defmodule Mead.Session.AbandonTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Pending
  alias Mead.Session.Server
  alias Mead.Session.Store
  alias Mead.Session.Turn
  alias Mead.Test.ResumableHandler

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous_storage do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    %{directory: directory}
  end

  defp start_session! do
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  # Starts a keyed turn and waits until it recorded its first step and blocks.
  defp start_keyed_turn(session_id) do
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
    assert_receive {:handler_at, handler_pid, [:a]}
    {caller, handler_pid}
  end

  defp flush_resumed do
    receive do
      {:resumed_with, _steps} -> flush_resumed()
    after
      0 -> :ok
    end
  end

  defp stored_turns(directory, session_id) do
    {:ok, turns} = Store.load(directory, session_id)
    turns
  end

  test "stopping a session mid keyed turn interrupts it for good", %{directory: directory} do
    session_id = start_session!()
    {caller, _handler_pid} = start_keyed_turn(session_id)

    assert Mead.stop_session(session_id) == :ok
    assert Task.await(caller) == {:error, :session_stopped}
    assert [%Turn{status: :interrupted, steps: []}] = stored_turns(directory, session_id)
    assert Pending.list(directory) == []

    assert Mead.resume_session(session_id, handler: ResumableHandler) == {:ok, session_id}
    assert {:ok, [%Turn{status: :interrupted}]} = Mead.history(session_id)
    refute_received {:resumed_with, _steps}
  end

  test "a stop right after a server crash still interrupts the turn for good",
       %{directory: directory} do
    session_id = start_session!()
    {_caller, _handler_pid} = start_keyed_turn(session_id)
    Process.exit(Session.whereis(session_id, :server), :kill)

    assert Mead.stop_session(session_id) == :ok
    assert [%Turn{status: :interrupted}] = stored_turns(directory, session_id)
    assert Pending.list(directory) == []

    # The restarted server may have begun continuing the turn before the stop reached it; only a
    # continuation after the stop would be wrong.
    flush_resumed()
    assert Mead.resume_session(session_id, handler: ResumableHandler) == {:ok, session_id}
    assert {:ok, [%Turn{status: :interrupted}]} = Mead.history(session_id)
    refute_received {:resumed_with, _steps}
  end

  test "deleting a session mid keyed turn removes its marker", %{directory: directory} do
    session_id = start_session!()
    {caller, _handler_pid} = start_keyed_turn(session_id)

    assert Mead.delete_session(session_id) == :ok
    assert Task.await(caller) == {:error, :session_stopped}
    assert Pending.list(directory) == []
  end

  test "deleting a stopped session removes a marker left behind", %{directory: directory} do
    session_id = Mead.UUID.generate()
    :ok = Store.append(directory, session_id, {:append, Turn.start("lost", "key-1")})
    :ok = Pending.mark(directory, session_id, %{handler: ResumableHandler, turn_timeout: 1_000})

    assert Mead.delete_session(session_id) == :ok
    assert Pending.list(directory) == []
  end

  test "an abandoned server refuses every later submit" do
    session_id = start_session!()

    assert Server.abandon(session_id) == :ok
    assert Mead.submit_turn(session_id, {:echo, "late"}) == {:error, :session_stopped}

    assert Mead.submit_turn(session_id, {:echo, "late"}, client_turn_id: "key-2") ==
             {:error, :session_stopped}
  end

  test "suspending keeps the turn in progress with its marker", %{directory: directory} do
    session_id = start_session!()
    {caller, handler_pid} = start_keyed_turn(session_id)
    handler_monitor = Process.monitor(handler_pid)

    assert Server.suspend(session_id) == :ok
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler_pid, _reason}

    assert [%Turn{status: :in_progress, steps: [:a], client_turn_id: "key-1"}] =
             stored_turns(directory, session_id)

    assert [{^session_id, _settings}] = Pending.list(directory)
    server = Session.whereis(session_id, :server)
    assert GenServer.call(server, {:submit, {:echo, "late"}, []}) == {:error, :session_suspended}

    # The waiter is told the session is suspended and keeps waiting for it to come back.
    refute Task.yield(caller, 100)
    Task.shutdown(caller, :brutal_kill)
  end

  test "a suspended turn continues when the session comes back", %{directory: directory} do
    session_id = start_session!()
    {caller, _handler_pid} = start_keyed_turn(session_id)
    :ok = Server.suspend(session_id)
    Task.shutdown(caller, :brutal_kill)

    # As in an orderly shutdown: the pair is terminated without being abandoned.
    supervisor = Session.whereis(session_id, :supervisor)
    :ok = DynamicSupervisor.terminate_child(Session.Pool, supervisor)
    wait_until(fn -> Session.whereis(session_id, :history) == nil end)
    assert [{^session_id, _settings}] = Pending.list(directory)

    assert Mead.resume_session(session_id, handler: ResumableHandler) == {:ok, session_id}
    assert_receive {:resumed_with, [:a]}
  end

  test "stopping a session after a suspend still interrupts its turn", %{directory: directory} do
    session_id = start_session!()
    {caller, _handler_pid} = start_keyed_turn(session_id)
    :ok = Server.suspend(session_id)
    Task.shutdown(caller, :brutal_kill)

    assert Mead.stop_session(session_id) == :ok
    assert [%Turn{status: :interrupted}] = stored_turns(directory, session_id)
    assert Pending.list(directory) == []
  end

  test "abandoning or suspending an unknown session is a no-op" do
    assert Server.abandon(Mead.UUID.generate()) == :unreachable
    assert Server.suspend(Mead.UUID.generate()) == :ok
  end
end
