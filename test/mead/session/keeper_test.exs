defmodule Mead.Session.KeeperTest do
  # Sets the global :storage setting and kills a root child, so it must not run beside other
  # tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Keeper
  alias Mead.Session.Pending
  alias Mead.Session.Store
  alias Mead.Session.Turn
  alias Mead.Test.ResumableHandler

  @moduletag :tmp_dir
  @moduletag :capture_log

  @settings %{handler: ResumableHandler, turn_timeout: 30_000}
  @turn_options %{route: :auto, tools: nil, interactive: false}

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

  defp stopped_keyed_turn(directory) do
    session_id = Mead.UUID.generate()
    turn = Turn.start({:checkpointed, self(), [:a]}, "key-1", @turn_options)
    :ok = Pending.mark(directory, session_id, @settings)
    :ok = Store.append(directory, session_id, {:append, turn})
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  defp finished?(session_id) do
    match?({:ok, [%Turn{status: :ok}]}, Mead.history(session_id))
  end

  test "recovery resumes a marked session and its turn finishes", %{directory: directory} do
    session_id = stopped_keyed_turn(directory)

    assert Keeper.recover(directory) == :ok
    assert_receive {:resumed_with, []}
    assert_receive {:handler_at, handler_pid, [:a]}
    send(handler_pid, :release)

    wait_until(fn -> finished?(session_id) end)
    wait_until(fn -> Pending.list(directory) == [] end)
  end

  test "recovery leaves a running session alone", %{directory: directory} do
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler)
    on_exit(fn -> Mead.stop_session(session_id) end)
    :ok = Pending.mark(directory, session_id, @settings)

    assert Keeper.recover(directory) == :ok
    assert [{^session_id, _settings}] = Pending.list(directory)
  end

  test "recovery removes the marker of an unknown session", %{directory: directory} do
    :ok = Pending.mark(directory, Mead.UUID.generate(), @settings)

    assert Keeper.recover(directory) == :ok
    assert Pending.list(directory) == []
  end

  test "recovery removes the marker of a damaged file", %{directory: directory} do
    session_id = Mead.UUID.generate()
    :ok = Store.append(directory, session_id, {:append, Turn.start("a")})
    :ok = Store.append(directory, session_id, {:append, Turn.start("b")})
    file = Path.join(directory, session_id <> ".log")
    <<head::binary-size(20), byte, tail::binary>> = File.read!(file)
    File.write!(file, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
    :ok = Pending.mark(directory, session_id, @settings)

    assert Keeper.recover(directory) == :ok
    assert Pending.list(directory) == []
  end

  test "recovery keeps the marker of a handler that no longer validates, and goes on",
       %{directory: directory} do
    broken = Mead.UUID.generate()
    :ok = Store.append(directory, broken, {:append, Turn.start("lost", "key-1", @turn_options)})
    :ok = Pending.mark(directory, broken, %{@settings | handler: Mead.NoSuchHandler})
    working = stopped_keyed_turn(directory)

    assert Keeper.recover(directory) == :ok
    assert_receive {:handler_at, handler_pid, [:a]}
    send(handler_pid, :release)
    wait_until(fn -> finished?(working) end)

    assert [{^broken, _settings}] = Pending.list(directory)
  end

  test "a pool restart restarts the keeper, which continues the turn the restart cut short" do
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
    assert_receive {:handler_at, _handler_pid, [:a]}

    keeper = Process.whereis(Keeper)
    Process.exit(Process.whereis(Session.Pool), :kill)
    assert {:error, _reason} = Task.await(caller)

    wait_until(fn -> Process.whereis(Keeper) not in [nil, keeper] end)
    assert_receive {:resumed_with, [:a]}, 5_000
    assert_receive {:handler_at, handler_pid, [:a, :b]}
    send(handler_pid, :release)
    wait_until(fn -> finished?(session_id) end)
  end

  test "suspending every session leaves the running turn in progress, and prep_stop does it",
       %{directory: directory} do
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
    assert_receive {:handler_at, _handler_pid, [:a]}

    on_exit(fn -> Supervisor.restart_child(Mead.Supervisor, Mead.MCP.Server) end)
    assert Mead.Application.prep_stop(:state) == :state
    Task.shutdown(caller, :brutal_kill)

    # The listener stops before the sessions are suspended, so no turn starts after them.
    assert {Mead.MCP.Server, :undefined, :supervisor, _modules} =
             List.keyfind(Supervisor.which_children(Mead.Supervisor), Mead.MCP.Server, 0)

    assert {:ok, [%Turn{status: :in_progress, steps: [:a]}]} = Mead.history(session_id)
    assert [{^session_id, _settings}] = Pending.list(directory)
    assert Mead.submit_turn(session_id, {:echo, "late"}) == {:error, :session_stopped}
    assert Keeper.suspend_all() == :ok
  end
end
