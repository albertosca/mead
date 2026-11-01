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

  test "a keyed turn continues from its checkpoint after its server is killed" do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a, :b]}
    caller = submit(session_id, input, "key-1")
    assert_receive {:handler_at, _pid, [:a]}

    kill_server(session_id)
    assert Task.await(caller) == {:error, :session_crashed}

    assert_receive {:resumed_with, [:a]}
    assert_receive {:handler_at, handler_pid, [:a, :b]}

    retry = submit(session_id, input, "key-1")
    wait_until(fn -> waiting?(session_id) end)
    send(handler_pid, :release)

    assert Task.await(retry) == {:ok, [:a, :b]}

    assert {:ok, [%Turn{status: :ok, output: [:a, :b], steps: [], resumes: 1}]} =
             Mead.history(session_id)
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
    Task.await(caller)

    assert_receive {:handler_options, continued}
    assert continued[:route] == :cloud
    assert continued[:tools] == :effect
    assert continued[:session_id] == session_id
    assert is_function(continued[:checkpoint], 1)
    assert first[:route] == :cloud
    assert is_function(first[:checkpoint], 1)
  end

  test "an unkeyed turn is interrupted when its server is killed" do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input) end)
    assert_receive {:handler_at, _pid, [:a]}

    kill_server(session_id)
    Task.await(caller)

    wait_until(fn -> match?({:ok, [%Turn{status: :interrupted}]}, Mead.history(session_id)) end)
    refute_received {:resumed_with, _steps}
  end

  test "a keyed turn of a handler that cannot continue is interrupted" do
    session_id = start_session!(ScriptedHandler)
    caller = submit(session_id, {:block, self()}, "key-1")
    assert_receive {:handler_started, _pid}

    kill_server(session_id)
    Task.await(caller)

    wait_until(fn -> match?({:ok, [%Turn{status: :interrupted}]}, Mead.history(session_id)) end)
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
    Task.await(kill_and_wait(session_id, caller))

    for steps <- [[:a, :b], [:a, :b, :c]] do
      assert_receive {:handler_at, _pid, ^steps}
      kill_server(session_id)
    end

    assert_receive {:handler_at, _pid, [:a, :b, :c, :d]}
    kill_server(session_id)

    wait_until(fn -> match?({:ok, [%Turn{status: :interrupted}]}, Mead.history(session_id)) end)
    assert Session.whereis(session_id, :supervisor) == supervisor
    refute_receive {:handler_at, _pid, _steps}, 200
  end

  defp kill_and_wait(session_id, caller) do
    kill_server(session_id)
    caller
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

  test "an unkeyed turn is not marked", %{directory: directory} do
    session_id = start_session!()
    input = {:checkpointed, self(), [:a]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input) end)
    assert_receive {:handler_at, handler_pid, [:a]}

    assert Pending.list(directory) == []
    send(handler_pid, :release)
    Task.await(caller)
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
    Task.await(caller)
    assert_receive {:resumed_with, [:a]}

    assert History.append_step(session_id, 0, :late) == {:error, :stale}
  end
end
