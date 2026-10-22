defmodule Mead.ApplicationTest do
  # Kills a root child, which restarts other sessions' infrastructure, so it must not overlap
  # with the asynchronous tests.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  test "the root supervisor starts the ledger, the registry, the turn supervisor, the pool, and the MCP hub in that order" do
    child_ids =
      Mead.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {child_id, _pid, _type, _modules} -> child_id end)
      |> Enum.reverse()

    assert child_ids == [
             Mead.Ledger,
             Mead.Registry,
             Mead.TurnSupervisor,
             Mead.Session.Pool,
             Mead.MCP.Hub
           ]
  end

  test "the root supervisor restarts later children when an earlier one dies (rest_for_one)" do
    ledger_pid = Process.whereis(Mead.Ledger)
    assert is_pid(ledger_pid)
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
    assert Process.whereis(Mead.Ledger) == ledger_pid
    assert Process.whereis(Mead.Registry) == registry_pid
    assert Process.whereis(Mead.TurnSupervisor) != turn_supervisor_pid
  end

  test "killing the hub restarts only the hub" do
    hub_pid = Process.whereis(Mead.MCP.Hub)
    pool_pid = Process.whereis(Mead.Session.Pool)
    ledger_pid = Process.whereis(Mead.Ledger)

    Process.exit(hub_pid, :kill)

    new_hub_pid =
      wait_until(fn ->
        candidate = Process.whereis(Mead.MCP.Hub)
        candidate != hub_pid and candidate
      end)

    assert is_pid(new_hub_pid)
    assert Process.whereis(Mead.Session.Pool) == pool_pid
    assert Process.whereis(Mead.Ledger) == ledger_pid
    assert Mead.MCP.Hub.tools_for([]) == []
  end
end
