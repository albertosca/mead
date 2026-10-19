defmodule Mead.LedgerSessionTest do
  # Reads the application environment, which is global, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Ledger
  alias Mead.Test.FakeProvider

  setup do
    previous = Application.fetch_env(:mead, :router)

    Application.put_env(:mead, :router,
      slots: [
        local: nil,
        cloud:
          {FakeProvider,
           test_pid: self(), result: {:ok, %{text: "cloud reply", usage: FakeProvider.usage()}}}
      ]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :router, value)
        :error -> Application.delete_env(:mead, :router)
      end
    end)

    {:ok, session_id} = Mead.start_session(handler: Mead.Router)
    on_exit(fn -> Mead.stop_session(session_id) end)

    %{session_id: session_id}
  end

  test "a routed turn is attributed to the session it ran in", %{session_id: session_id} do
    assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")

    assert {:ok, %{turns: 1, failures: 0, input_tokens: 5, output_tokens: 3}} =
             Ledger.session_totals(session_id)
  end

  test "a failed turn counts as a failure for its session", %{session_id: session_id} do
    assert {:error, {:failed, :local_unavailable}} =
             Mead.submit_turn(session_id, "list my tasks", route: :local)

    assert {:ok, %{turns: 1, failures: 1}} = Ledger.session_totals(session_id)
  end

  test "stopping a session forgets its aggregate but not the route totals", %{
    session_id: session_id
  } do
    Mead.submit_turn(session_id, "explain this")
    before_stop = Ledger.route_totals()[{:cloud, FakeProvider}].turns

    assert :ok = Mead.stop_session(session_id)

    assert Ledger.session_totals(session_id) == {:error, :not_found}
    assert Ledger.route_totals()[{:cloud, FakeProvider}].turns >= before_stop
  end

  test "the ledger survives a crash of the turn supervisor", %{session_id: session_id} do
    Mead.submit_turn(session_id, "explain this")
    ledger_pid = Process.whereis(Ledger)
    assert is_pid(ledger_pid)
    turn_supervisor_pid = Process.whereis(Mead.TurnSupervisor)

    Process.exit(turn_supervisor_pid, :kill)

    Mead.TestHelpers.wait_until(fn ->
      candidate = Process.whereis(Mead.TurnSupervisor)
      candidate != turn_supervisor_pid and candidate
    end)

    assert Process.whereis(Ledger) == ledger_pid
    assert {:ok, %{turns: 1}} = Ledger.session_totals(session_id)
  end
end
