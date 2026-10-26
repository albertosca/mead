defmodule Mead.ApplicationTest do
  # Kills a root child, which restarts other sessions' infrastructure, so it must not overlap
  # with the asynchronous tests.
  use ExUnit.Case, async: false

  # The root supervisor tolerates 10 restarts in 5 seconds, well above the 3 of OTP's default,
  # so a test may kill a root child without the suite's earlier kills (this file kills the turn
  # supervisor and the hub, and ledger_session_test.exs kills the turn supervisor) having spent
  # the budget. That the server, the last child, restarts alone follows from rest_for_one and
  # the order test below.

  import Mead.TestHelpers

  # An earlier test may have killed the hub or an earlier child, and the server, restarted last,
  # may not be registered yet.
  defp running_server, do: wait_until(fn -> Process.whereis(Mead.MCP.Server) end)

  test "the root supervisor starts the ledger, the registry, the turn supervisor, the pool, the MCP hub, the deck tickets, and the MCP server in that order" do
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
             Mead.MCP.Hub,
             Mead.Deck.Tickets,
             Mead.MCP.Server
           ]
  end

  test "the root supervisor tolerates a burst of restarts that OTP's default budget would not" do
    options = Mead.Application.supervisor_options()
    assert options[:strategy] == :rest_for_one
    assert options[:max_restarts] == 10
    assert options[:max_seconds] == 5

    # What the budget means: a child killed five times in a row does not take the supervisor down.
    {:ok, supervisor} =
      Supervisor.start_link(
        [%{id: :worker, start: {Agent, :start_link, [fn -> :ok end]}}],
        Keyword.delete(options, :name)
      )

    for _kill <- 1..5 do
      worker = wait_until(fn -> restarted_worker(supervisor) end)
      Process.exit(worker, :kill)

      wait_until(fn ->
        restarted_worker(supervisor) != worker and restarted_worker(supervisor)
      end)
    end

    assert Process.alive?(supervisor)
  end

  defp restarted_worker(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{:worker, worker, :worker, _modules}] when is_pid(worker) -> worker
      _restarting -> false
    end
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

  test "killing the hub restarts the hub and the server, and nothing before them" do
    hub_pid = Process.whereis(Mead.MCP.Hub)
    server_pid = running_server()
    pool_pid = Process.whereis(Mead.Session.Pool)
    ledger_pid = Process.whereis(Mead.Ledger)

    Process.exit(hub_pid, :kill)

    new_hub_pid =
      wait_until(fn ->
        candidate = Process.whereis(Mead.MCP.Hub)
        candidate != hub_pid and candidate
      end)

    assert is_pid(new_hub_pid)

    assert wait_until(fn ->
             candidate = Process.whereis(Mead.MCP.Server)
             candidate != server_pid and candidate
           end)

    assert Process.whereis(Mead.Session.Pool) == pool_pid
    assert Process.whereis(Mead.Ledger) == ledger_pid
    assert Mead.MCP.Hub.tools_for([]) == []
  end

  test "without a token in the application environment the server holds no listener" do
    running_server()

    assert Supervisor.which_children(Mead.MCP.Server) == []
    assert Mead.MCP.Server.port() == :error
  end

  test "the token read from the application environment is in no process status" do
    token = "application-env-sentinel-0123456789"
    Application.put_env(:mead, :mcp_server, token: token, port: 0)
    on_exit(fn -> Application.delete_env(:mead, :mcp_server) end)

    start_supervised!({Mead.MCP.Server, name: :redaction_server})
    [{_id, listener, :supervisor, _modules}] = Supervisor.which_children(:redaction_server)

    for process <- [:redaction_server, listener] do
      status =
        process |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

      refute status =~ token
    end
  end
end
