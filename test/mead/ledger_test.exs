defmodule Mead.LedgerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Ledger

  # Each test owns a ledger listening on an event only that test emits, so tests do not see each
  # other's turns even though telemetry handlers are global.
  setup do
    name = :"ledger_#{System.unique_integer([:positive])}"
    event = [:mead_test, name]
    start_supervised!({Ledger, name: name, event: event})

    %{ledger: name, event: event}
  end

  defp emit(event, overrides \\ %{}, measurement_overrides \\ %{}) do
    metadata =
      Map.merge(
        %{
          route: :cloud,
          route_source: :classified,
          provider: Mead.Test.FakeProvider,
          status: :ok,
          session_id: "session-a"
        },
        overrides
      )

    measurements =
      Map.merge(
        %{
          duration: System.convert_time_unit(7, :millisecond, :native),
          input_tokens: 5,
          output_tokens: 3
        },
        measurement_overrides
      )

    :telemetry.execute(event, measurements, metadata)
  end

  describe "aggregates" do
    test "a session's totals add up its turns", %{event: event, ledger: ledger} do
      emit(event)
      emit(event, %{}, %{input_tokens: 10, output_tokens: 1})

      assert Ledger.session_totals("session-a", ledger) ==
               {:ok,
                %{turns: 2, failures: 0, input_tokens: 15, output_tokens: 4, duration_ms: 14}}
    end

    test "a failed turn counts as a failure with the tokens it reported", %{
      event: event,
      ledger: ledger
    } do
      emit(event, %{status: :error}, %{input_tokens: 0, output_tokens: 0})

      assert {:ok, %{turns: 1, failures: 1, input_tokens: 0, output_tokens: 0}} =
               Ledger.session_totals("session-a", ledger)
    end

    test "an unknown session is not found rather than zero", %{ledger: ledger} do
      assert Ledger.session_totals("never-seen", ledger) == {:error, :not_found}
    end

    test "route totals are kept per route and provider", %{event: event, ledger: ledger} do
      emit(event)

      emit(event, %{route: :local, provider: nil, status: :error}, %{
        input_tokens: 0,
        output_tokens: 0
      })

      totals = Ledger.route_totals(ledger)

      assert totals[{:cloud, Mead.Test.FakeProvider}].turns == 1

      assert totals[{:local, nil}] == %{
               turns: 1,
               failures: 1,
               input_tokens: 0,
               output_tokens: 0,
               duration_ms: 7
             }
    end

    test "the overall totals sum every route and report the dropped events", %{
      event: event,
      ledger: ledger
    } do
      emit(event)
      emit(event, %{route: :local, provider: nil})

      assert Ledger.totals(ledger) == %{
               turns: 2,
               failures: 0,
               input_tokens: 10,
               output_tokens: 6,
               duration_ms: 14,
               dropped: 0
             }
    end

    test "a turn outside a session counts in the route totals only", %{
      event: event,
      ledger: ledger
    } do
      emit(event, %{session_id: nil})

      assert Ledger.totals(ledger).turns == 1
      assert Ledger.session_totals("session-a", ledger) == {:error, :not_found}
    end

    test "two sessions turning concurrently keep their own totals and lose no increment", %{
      event: event,
      ledger: ledger
    } do
      tasks =
        for session_id <- ["session-a", "session-b"], _round <- 1..20 do
          Task.async(fn ->
            for _turn <- 1..50, do: emit(event, %{session_id: session_id})
          end)
        end

      Task.await_many(tasks)

      for session_id <- ["session-a", "session-b"] do
        assert {:ok, %{turns: 1000, input_tokens: 5000, output_tokens: 3000}} =
                 Ledger.session_totals(session_id, ledger)
      end

      assert Ledger.totals(ledger).turns == 2000
    end
  end

  describe "malformed events" do
    test "are counted as dropped and the next valid event is still recorded", %{
      event: event,
      ledger: ledger
    } do
      emit(event, %{status: :weird})
      emit(event, %{session_id: 42})
      emit(event, %{route: "cloud"})
      emit(event, %{}, %{input_tokens: -1})
      emit(event, %{}, %{input_tokens: "5"})
      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{duration: 1}, %{route: :cloud})

      assert Ledger.totals(ledger).dropped == 7
      assert Ledger.totals(ledger).turns == 0

      emit(event)

      assert Ledger.totals(ledger).turns == 1
    end
  end

  describe "a killed ledger" do
    test "leaves a handler that neither raises nor gets detached" do
      name = :"killed_ledger_#{System.unique_integer([:positive])}"
      event = [:mead_test, name]
      {:ok, pid} = Ledger.start_link(name: name, event: event)
      Process.unlink(pid)
      reference = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}

      log = capture_log(fn -> emit(event) end)

      # The log is global, so unrelated tests may write to it; only a detach of this handler counts.
      refute log =~ inspect({Ledger, name})
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == {Ledger, name}))

      :telemetry.detach({Ledger, name})
    end
  end
end
