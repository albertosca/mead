defmodule Mead.WatchdogTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.Watchdog

  @moduletag :capture_log

  # Starts an agent while the switch says :up and refuses while it says :down, telling the test
  # about every attempt.
  def start_switched(switch, test_pid) do
    send(test_pid, {:attempt, System.monotonic_time(:millisecond)})

    case Agent.get(switch, & &1) do
      :up -> Agent.start_link(fn -> :child end)
      :down -> {:error, :refused}
    end
  end

  defp start_watchdog!(switch, options \\ []) do
    options =
      Keyword.merge(
        [start: {__MODULE__, :start_switched, [switch, self()]}, initial_delay: 10],
        options
      )

    start_supervised!({Watchdog, options})
  end

  defp switch!(position) do
    {:ok, switch} = Agent.start_link(fn -> position end)
    switch
  end

  defp restarted_child(watchdog, old_child) do
    wait_until(fn ->
      candidate = Watchdog.child(watchdog)
      is_pid(candidate) and candidate != old_child and candidate
    end)
  end

  test "starts its child again after the child exits" do
    watchdog = start_watchdog!(switch!(:up))
    child = Watchdog.child(watchdog)
    assert is_pid(child)

    Process.exit(child, :kill)

    assert restarted_child(watchdog, child) != child
  end

  # A supervisor that gives up exits with :shutdown, the same reason an orderly stop uses, so the
  # reason cannot tell the watchdog whether to restart: only its own parent stopping it can.
  test "starts its child again after the child exits with :shutdown" do
    watchdog = start_watchdog!(switch!(:up))
    child = Watchdog.child(watchdog)

    Process.exit(child, :shutdown)

    assert restarted_child(watchdog, child) != child
  end

  test "a first start that fails fails the watchdog's own start" do
    Process.flag(:trap_exit, true)

    assert Watchdog.start_link(start: {__MODULE__, :start_switched, [switch!(:down), self()]}) ==
             {:error, :refused}
  end

  test "keeps trying while the child cannot start, doubling the wait up to the maximum" do
    switch = switch!(:up)
    watchdog = start_watchdog!(switch, initial_delay: 10, maximum_delay: 40)
    assert_receive {:attempt, _first}
    child = Watchdog.child(watchdog)

    Agent.update(switch, fn _position -> :down end)
    Process.exit(child, :kill)

    attempts =
      for _attempt <- 1..5 do
        assert_receive {:attempt, at}, 1_000
        at
      end

    gaps =
      attempts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [earlier, later] -> later - earlier end)

    assert Enum.at(gaps, 0) >= 20
    assert Enum.at(gaps, 1) >= 40
    assert Watchdog.child(watchdog) == nil
    assert :sys.get_state(watchdog).delay == 40

    Agent.update(switch, fn _position -> :up end)
    assert is_pid(restarted_child(watchdog, nil))
  end

  test "a child that stayed up long enough is started again after the initial wait" do
    switch = switch!(:up)
    watchdog = start_watchdog!(switch, initial_delay: 10, maximum_delay: 5_000, stable_after: 50)
    child = Watchdog.child(watchdog)

    # Two quick exits raise the wait.
    Process.exit(child, :kill)
    child = restarted_child(watchdog, child)
    Process.exit(child, :kill)
    child = restarted_child(watchdog, child)
    assert :sys.get_state(watchdog).delay == 40

    Process.sleep(100)
    Process.exit(child, :kill)
    restarted_child(watchdog, child)

    assert :sys.get_state(watchdog).delay == 20
  end

  test "stopping the watchdog shuts its child down" do
    watchdog = start_watchdog!(switch!(:up))
    child = Watchdog.child(watchdog)
    reference = Process.monitor(child)

    stop_supervised!(Watchdog)

    assert_receive {:DOWN, ^reference, :process, ^child, :shutdown}
    refute Process.alive?(watchdog)
  end

  test "after stand_down a child that exits stays down" do
    watchdog = start_watchdog!(switch!(:up))
    assert_receive {:attempt, _first}
    child = Watchdog.child(watchdog)

    assert Watchdog.stand_down(watchdog) == :ok
    Process.exit(child, :kill)

    refute_receive {:attempt, _later}, 200
    assert Watchdog.child(watchdog) == nil
  end
end
