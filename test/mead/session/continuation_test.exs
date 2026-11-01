defmodule Mead.Session.ContinuationTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.History
  alias Mead.Session.Pending
  alias Mead.Session.Store
  alias Mead.Session.Turn
  alias Mead.Test.ResumableHandler
  alias Mead.Test.ScriptedHandler

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 20_000

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

  defp start_session!(handler \\ ResumableHandler) do
    {:ok, session_id} = Mead.start_session(handler: handler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  defp kill_server(session_id) do
    old_pid = Session.whereis(session_id, :server)
    Process.exit(old_pid, :kill)

    wait_until(fn ->
      candidate = Session.whereis(session_id, :server)
      candidate != old_pid and candidate
    end)
  end

  defp submit(session_id, input, key) do
    Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: key) end)
  end

  defp stored_newest(directory, session_id) do
    {:ok, turns} = Store.load(directory, session_id)
    List.last(turns)
  end

  defmodule UnsafeToRepeatHandler do
    @moduledoc false
    @behaviour Mead.Session.TurnHandler

    @impl true
    def handle_turn(_history, {:side_effect, test_pid}, _options) do
      send(test_pid, {:side_effect_ran, self()})

      receive do
        :release -> {:ok, :done}
      end
    end

    @impl true
    def resume_turn(_history, _input, _steps, _options), do: {:error, :not_resumable}
  end

  # The minimal safe resume_turn/4 the guides recommend for a turn that must not run twice.
  test "a handler that answers :not_resumable ends the cut turn as failed and repeats nothing" do
    session_id = start_session!(UnsafeToRepeatHandler)
    caller = submit(session_id, {:side_effect, self()}, "once")
    assert_receive {:side_effect_ran, _pid}

    kill_server(session_id)

    assert Task.await(caller) == {:error, {:failed, :not_resumable}}
    refute_received {:side_effect_ran, _pid}
    assert {:ok, [%Turn{status: status}]} = Mead.history(session_id)
    refute status in [:ok, :in_progress]
  end

  # The caller of a keyed turn never learns its server restarted: the submission waits through
  # the restart and returns what the continued turn returns.
  test "a keyed turn continues from its checkpoint and its caller gets the outcome" do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a, :b]}
    caller = submit(session_id, input, "key-1")
    assert_receive {:handler_at, _pid, [:a]}

    kill_server(session_id)

    assert_receive {:resumed_with, [:a]}
    assert_receive {:handler_at, handler_pid, [:a, :b]}
    wait_until(fn -> waiting?(session_id) end)
    send(handler_pid, :release)

    assert Task.await(caller) == {:ok, [:a, :b]}

    assert {:ok, [%Turn{status: :ok, output: [:a, :b], steps: [], resumes: 1}]} =
             Mead.history(session_id)
  end

  # Each crash proves the server came back and took the turn again, so the wait starts again
  # there; a turn that runs for longer than the wait between two crashes still reaches its caller.
  test "a keyed caller waits through a second crash that comes after the wait" do
    previous_wait = Application.fetch_env(:mead, :restart_wait)
    Application.put_env(:mead, :restart_wait, 300)

    on_exit(fn ->
      case previous_wait do
        {:ok, value} -> Application.put_env(:mead, :restart_wait, value)
        :error -> Application.delete_env(:mead, :restart_wait)
      end
    end)

    session_id = start_session!()
    caller = submit(session_id, {:checkpointed, self(), [:a, :b, :c]}, "key-1")
    assert_receive {:handler_at, _pid, [:a]}
    kill_server(session_id)
    assert_receive {:handler_at, _pid, [:a, :b]}

    Process.sleep(500)
    kill_server(session_id)
    assert_receive {:handler_at, handler_pid, [:a, :b, :c]}
    wait_until(fn -> waiting?(session_id) end)
    send(handler_pid, :release)

    assert Task.await(caller) == {:ok, [:a, :b, :c]}
  end

  test "a keyed caller whose server does not come back within the wait gets :session_crashed" do
    previous_wait = Application.fetch_env(:mead, :restart_wait)
    Application.put_env(:mead, :restart_wait, 200)

    on_exit(fn ->
      case previous_wait do
        {:ok, value} -> Application.put_env(:mead, :restart_wait, value)
        :error -> Application.delete_env(:mead, :restart_wait)
      end
    end)

    session_id = start_session!()
    supervisor = Session.whereis(session_id, :supervisor)
    caller = submit(session_id, {:checkpointed, self(), [:a, :b]}, "key-1")
    assert_receive {:handler_at, _pid, [:a]}

    # A suspended supervisor cannot start the server again until it is resumed.
    :sys.suspend(supervisor)
    Process.exit(Session.whereis(session_id, :server), :kill)

    assert Task.await(caller) == {:error, :session_crashed}

    :sys.resume(supervisor)
    assert_receive {:handler_at, handler_pid, [:a, :b]}
    send(handler_pid, :release)
  end

  test "a keyed submission to an unknown session is not found at once" do
    started = System.monotonic_time(:millisecond)

    assert Mead.submit_turn(Mead.UUID.generate(), :anything, client_turn_id: "key-1") ==
             {:error, :not_found}

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  defp waiting?(session_id) do
    session_id
    |> Session.whereis(:server)
    |> :sys.get_state()
    |> get_in([:running, :waiters])
    |> length() == 1
  end

  test "a continued turn gets the options it was submitted with" do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a, :b]}

    caller =
      Task.async(fn ->
        Mead.submit_turn(session_id, input,
          client_turn_id: "key-1",
          route: :cloud,
          tools: :effect
        )
      end)

    assert_receive {:handler_options, first}
    assert_receive {:handler_at, _pid, [:a]}
    kill_server(session_id)

    assert_receive {:handler_options, continued}
    assert_receive {:handler_at, handler_pid, [:a, :b]}
    send(handler_pid, :release)
    assert Task.await(caller) == {:ok, [:a, :b]}
    assert continued[:route] == :cloud
    assert continued[:tools] == :effect
    assert continued[:session_id] == session_id
    assert is_function(continued[:checkpoint], 1)
    assert first[:route] == :cloud
    assert is_function(first[:checkpoint], 1)
  end

  # A turn submitted without a key gets one from mead, so a crash continues it like any other.
  test "a turn submitted without a key continues after a crash and answers its caller" do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input) end)
    assert_receive {:handler_at, _pid, [:a]}

    kill_server(session_id)

    assert_receive {:resumed_with, [:a]}
    assert_receive {:handler_at, continued, [:a, :b]}
    send(continued, :release)

    assert Task.await(caller) == {:ok, [:a, :b]}

    assert {:ok, [%Turn{status: :ok, client_turn_id: "mead-" <> generated}]} =
             Mead.history(session_id)

    assert generated =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "two turns submitted without a key with the same input both run" do
    session_id = start_session!()

    assert Mead.submit_turn(session_id, {:echo, "same"}) == {:ok, "same"}
    assert Mead.submit_turn(session_id, {:echo, "same"}) == {:ok, "same"}

    assert {:ok, [%Turn{client_turn_id: first}, %Turn{client_turn_id: second}]} =
             Mead.history(session_id)

    assert is_binary(first) and is_binary(second)

    assert first != second
  end

  test "a keyed turn of a handler that resumes by running again runs again after a crash" do
    session_id = start_session!(ScriptedHandler)
    caller = submit(session_id, {:block, self()}, "key-1")
    assert_receive {:handler_started, _pid}

    kill_server(session_id)
    assert_receive {:handler_started, continued}
    send(continued, :release)

    assert Task.await(caller) == {:ok, :released}
    assert {:ok, [%Turn{status: :ok, output: :released}]} = Mead.history(session_id)
  end

  test "a keyed turn recorded without turn options is interrupted", %{directory: directory} do
    session_id = Mead.UUID.generate()
    :ok = Store.append(directory, session_id, {:append, Turn.start({:echo, "old"}, "key-1")})

    {:ok, ^session_id} = Mead.resume_session(session_id, handler: ResumableHandler)
    on_exit(fn -> Mead.stop_session(session_id) end)

    assert {:ok, [%Turn{status: :interrupted}]} = Mead.history(session_id)
  end

  test "the fourth start of a turn in progress interrupts it and the session stays up" do
    session_id = start_session!()
    supervisor = Session.whereis(session_id, :supervisor)
    caller = submit(session_id, {:checkpointed, self(), [:a, :b, :c, :d, :e]}, "key-1")
    assert_receive {:handler_at, _pid, [:a]}
    kill_server(session_id)

    for steps <- [[:a, :b], [:a, :b, :c]] do
      assert_receive {:handler_at, _pid, ^steps}
      kill_server(session_id)
    end

    assert_receive {:handler_at, _pid, [:a, :b, :c, :d]}
    kill_server(session_id)

    wait_until(fn -> match?({:ok, [%Turn{status: :interrupted}]}, Mead.history(session_id)) end)
    assert Session.whereis(session_id, :supervisor) == supervisor
    refute_receive {:handler_at, _pid, _steps}, 200
    assert Task.await(caller) == {:error, :interrupted}
  end

  test "a keyed turn is marked pending while it runs", %{directory: directory} do
    session_id = start_session!()
    caller = submit(session_id, {:checkpointed, self(), [:a]}, "key-1")
    assert_receive {:handler_at, handler_pid, [:a]}

    assert [{^session_id, %{handler: ResumableHandler, turn_timeout: 30_000}}] =
             Pending.list(directory)

    send(handler_pid, :release)
    assert Task.await(caller) == {:ok, [:a]}
    assert Pending.list(directory) == []
  end

  # The marker is what lets the keeper continue the turn after a node stop.
  test "a turn submitted without a key is marked pending while it runs", %{directory: directory} do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input) end)
    assert_receive {:handler_at, handler_pid, [:a]}

    assert [{^session_id, _options}] = Pending.list(directory)
    send(handler_pid, :release)
    Task.await(caller)
    assert Pending.list(directory) == []
  end

  test "a resumed session continues its keyed turn instead of interrupting it", %{
    directory: directory
  } do
    session_id = Mead.UUID.generate()
    test_pid = self()
    turn_options = %{route: :auto, tools: nil, interactive: false}
    started = Turn.start({:checkpointed, test_pid, [:a, :b]}, "key-1", turn_options)
    :ok = Store.append(directory, session_id, {:append, started})
    :ok = Store.append(directory, session_id, {:step, :a})

    {:ok, ^session_id} = Mead.resume_session(session_id, handler: ResumableHandler)
    on_exit(fn -> Mead.stop_session(session_id) end)

    assert_receive {:resumed_with, [:a]}
    assert_receive {:handler_at, handler_pid, [:a, :b]}
    send(handler_pid, :release)

    wait_until(fn ->
      match?(%Turn{status: :ok, output: [:a, :b]}, stored_newest(directory, session_id))
    end)
  end

  test "a late step from a killed attempt is refused" do
    session_id = start_session!()
    caller = submit(session_id, {:checkpointed, self(), [:a, :b]}, "key-1")
    assert_receive {:handler_at, _pid, [:a]}
    kill_server(session_id)
    assert_receive {:resumed_with, [:a]}

    assert History.append_step(session_id, 0, :late) == {:error, :stale}

    assert_receive {:handler_at, handler_pid, [:a, :b]}
    send(handler_pid, :release)
    assert Task.await(caller) == {:ok, [:a, :b]}
  end
end
