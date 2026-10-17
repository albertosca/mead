defmodule Mead.ApplicationTest do
  # Kills a root child, which restarts other sessions' infrastructure, so it must not overlap
  # with the asynchronous tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  test "the root supervisor starts the registry, the turn supervisor, and the pool in that order" do
    child_ids =
      Mead.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {child_id, _pid, _type, _modules} -> child_id end)
      |> Enum.reverse()

    assert child_ids == [Mead.Registry, Mead.TurnSupervisor, Mead.Session.Pool]
  end

  test "the root supervisor restarts later children when an earlier one dies (rest_for_one)" do
    registry_pid = Process.whereis(Mead.Registry)
    turn_supervisor_pid = Process.whereis(Mead.TurnSupervisor)
    pool_pid = Process.whereis(Mead.Session.Pool)

    Process.exit(turn_supervisor_pid, :kill)

    new_pool_pid =
      wait_until(fn ->
        candidate = Process.whereis(Mead.Session.Pool)
        candidate != pool_pid and candidate
      end)

    assert new_pool_pid != pool_pid
    assert Process.whereis(Mead.Registry) == registry_pid
    assert Process.whereis(Mead.TurnSupervisor) != turn_supervisor_pid
  end
end
