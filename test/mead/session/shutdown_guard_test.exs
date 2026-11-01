defmodule Mead.Session.ShutdownGuardTest do
  # Kills root children and sets the global :storage setting, so it must not run beside other
  # tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mead.TestHelpers

  alias Mead.Session.Turn
  alias Mead.Test.ResumableHandler

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: directory} do
    # Each test here kills a root child at least once; see Mead.ApplicationTest.
    await_root_restart_budget(2)
    previous_storage = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous_storage do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    input = {:checkpointed, self(), [:a, :b]}
    Task.start(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
    assert_receive {:handler_at, handler_pid, [:a]}

    %{session_id: session_id, handler_pid: handler_pid}
  end

  defp finished?(session_id), do: match?({:ok, [%Turn{status: :ok}]}, Mead.history(session_id))

  # Which of the two monitors fired first, by order of arrival.
  defp first_down(first, second) do
    receive do
      {:DOWN, ^first, :process, _pid, _reason} -> first
      {:DOWN, ^second, :process, _pid, _reason} -> second
    after
      5_000 -> flunk("nothing went down")
    end
  end

  defp kill_root_child(name) do
    pid = Process.whereis(name)
    Process.exit(pid, :kill)
    wait_until(fn -> Process.whereis(name) not in [nil, pid] end)
  end

  test "a crash before the hub suspends the running turns before the hub stops",
       %{session_id: session_id, handler_pid: handler_pid} do
    handler_monitor = Process.monitor(handler_pid)
    hub_monitor = Process.monitor(Process.whereis(Mead.MCP.Hub))

    kill_root_child(Mead.Ledger)

    # The turn stopped first, while the hub it might be calling was still up.
    assert first_down(handler_monitor, hub_monitor) == handler_monitor
    assert_receive {:DOWN, ^hub_monitor, :process, _pid, _reason}, 5_000

    assert_receive {:resumed_with, [:a]}, 5_000
    assert_receive {:handler_at, continued_pid, [:a, :b]}
    send(continued_pid, :release)
    wait_until(fn -> finished?(session_id) end)
  end

  # A crash that restarts the pool can knock the session more than once (each continued attempt
  # replays what the last recorded), and the session is not running once its turn is over, so
  # the outcome is read from its file.
  defp assert_continues(session_id, directory) do
    assert_receive {:resumed_with, [:a | _rest]}, 10_000
    release_handlers()

    wait_until(fn ->
      release_handlers()
      match?({:ok, [%Turn{status: :ok}]}, Mead.Session.Store.load(directory, session_id))
    end)
  end

  defp release_handlers do
    receive do
      {:handler_at, handler_pid, _steps} ->
        send(handler_pid, :release)
        release_handlers()
    after
      0 -> :ok
    end
  end

  test "a turn supervisor crash leaves the turn in progress, and it continues",
       %{session_id: session_id, tmp_dir: directory} do
    kill_root_child(Mead.TurnSupervisor)
    assert_continues(session_id, directory)
  end

  # The registry fails the way it can on its own: its partition crashes more often than the
  # registry's supervisor tolerates (3 in 5 seconds), so that supervisor stops its children and
  # exits, and the root restarts it and everything after it.
  test "a registry crash leaves the turn in progress, and it continues",
       %{session_id: session_id, tmp_dir: directory} do
    crash_registry()
    assert_continues(session_id, directory)
  end

  # Each crash restarts the pool and cuts the turn once, so four of them cut it more often than
  # the three continuations a turn gets when its own session keeps failing; none of these cuts is
  # the turn's fault. The turn has steps enough that no continuation finishes it early.
  test "repeated registry crashes do not spend the turn's crash budget",
       %{tmp_dir: directory, handler_pid: first_handler} do
    send(first_handler, :release)
    steps = Enum.to_list(1..8)
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 60_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    input = {:checkpointed, self(), steps}
    Task.start(fn -> Mead.submit_turn(session_id, input, client_turn_id: "storm") end)
    assert_receive {:handler_at, _handler_pid, [1]}, 5_000
    # Four root restarts in a row, and room for a later test's.
    await_root_restart_budget(6)

    for crash <- 1..4 do
      crash_registry()

      assert_receive {:resumed_with, [1 | _rest]},
                     10_000,
                     "no continuation after crash #{crash}"
    end

    wait_until(fn ->
      release_handlers()
      match?({:ok, [%Turn{status: :ok}]}, Mead.Session.Store.load(directory, session_id))
    end)

    {:ok, [turn]} = Mead.Session.Store.load(directory, session_id)
    assert turn.resumes >= 4
    assert turn.output == steps
  end

  defp crash_registry do
    registry = Process.whereis(Mead.Registry)
    registry_monitor = Process.monitor(registry)

    outcome =
      Enum.reduce_while(1..10, nil, fn _attempt, previous ->
        partition = wait_until(fn -> partition_other_than(previous) end)
        Process.exit(partition, :kill)

        receive do
          {:DOWN, ^registry_monitor, :process, _pid, _reason} -> {:halt, :down}
        after
          50 -> {:cont, partition}
        end
      end)

    assert outcome == :down
    wait_until(fn -> Process.whereis(Mead.Registry) not in [nil, registry] end)
  end

  # The guard finds the servers through the pool, so a registry that is gone does not crash it
  # before it suspends anything.
  test "suspend_all works while the registry is down", %{handler_pid: handler_pid} do
    handler_monitor = Process.monitor(handler_pid)

    log =
      capture_log(fn ->
        registry = Process.whereis(Mead.Registry)
        :ok = Supervisor.terminate_child(Mead.Supervisor, Mead.Registry)

        try do
          assert Process.whereis(Mead.Registry) == nil
          assert Mead.Session.Keeper.suspend_all() == :ok
          # The running turn was found and suspended, not just skipped.
          assert_received {:DOWN, ^handler_monitor, :process, ^handler_pid, _reason}
        after
          {:ok, _pid} = Supervisor.restart_child(Mead.Supervisor, Mead.Registry)
          refute Process.whereis(Mead.Registry) in [nil, registry]
        end
      end)

    refute log =~ "unknown registry"
  end

  defp partition_other_than(previous) do
    case Process.whereis(Mead.Registry.PIDPartition0) do
      nil -> false
      ^previous -> false
      partition -> partition
    end
  end

  test "a hub crash leaves the running turns alone",
       %{session_id: session_id, handler_pid: handler_pid} do
    kill_root_child(Mead.MCP.Hub)

    assert Process.alive?(handler_pid)
    send(handler_pid, :release)
    assert_receive {:handler_at, ^handler_pid, [:a, :b]}
    send(handler_pid, :release)
    wait_until(fn -> finished?(session_id) end)
    refute_received {:resumed_with, _steps}
  end
end
