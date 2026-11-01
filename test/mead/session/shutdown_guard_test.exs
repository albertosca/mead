defmodule Mead.Session.ShutdownGuardTest do
  # Kills root children and sets the global :storage setting, so it must not run beside other
  # tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

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
