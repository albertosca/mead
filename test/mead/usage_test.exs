defmodule Mead.UsageTest do
  use ExUnit.Case, async: true

  setup do
    name = :"usage_ledger_#{System.unique_integer([:positive])}"
    event = [:mead_test, name]
    start_supervised!({Mead.Ledger, name: name, event: event, directory: nil})
    %{name: name, event: event}
  end

  defp emit(context, overrides \\ %{}) do
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

    measurements = %{
      duration: System.convert_time_unit(7, :millisecond, :native),
      input_tokens: 5,
      output_tokens: 3
    }

    :telemetry.execute(context.event, measurements, metadata)
  end

  defp feed(context) do
    emit(context)
    emit(context, %{status: :error, route: :local, provider: Mead.Test.OtherProvider})
    emit(context, %{session_id: nil})
  end

  describe "usage/1" do
    test "reads the totals, the routes sorted and the recent turns newest first", context do
      feed(context)

      usage = Mead.usage(ledger: context.name)

      assert usage.totals == %{
               turns: 3,
               failures: 1,
               input_tokens: 15,
               output_tokens: 9,
               duration_ms: 21,
               dropped: 0
             }

      assert [
               %{route: :cloud, provider: Mead.Test.FakeProvider, turns: 2, failures: 0},
               %{route: :local, provider: Mead.Test.OtherProvider, turns: 1, failures: 1}
             ] = usage.routes

      assert [%{session_id: nil}, %{status: :error}, %{status: :ok, session_id: "session-a"}] =
               usage.recent
    end

    test "limits the recent turns, and zero asks for none", context do
      feed(context)

      assert length(Mead.usage(ledger: context.name, recent: 2).recent) == 2
      assert Mead.usage(ledger: context.name, recent: 0).recent == []
      assert length(Mead.usage(ledger: context.name).recent) == 3
    end

    test "refuses a recent that is not an integer from 0 to 100", context do
      for invalid <- [-1, 101, 1.5, "5", nil] do
        assert_raise ArgumentError, fn -> Mead.usage(ledger: context.name, recent: invalid) end
      end
    end

    test "refuses an unknown option and a non-keyword list", context do
      assert_raise ArgumentError, fn -> Mead.usage(ledger: context.name, windows: 1) end
      assert_raise ArgumentError, fn -> Mead.usage(:recent) end
    end
  end

  describe "session_usage/2" do
    test "returns what the ledger counted for the session", context do
      feed(context)

      assert {:ok, %{turns: 2, failures: 1, input_tokens: 10, output_tokens: 6, duration_ms: 14}} =
               Mead.session_usage("session-a", context.name)
    end

    test "an unknown session is not found", context do
      assert Mead.session_usage("nobody", context.name) == {:error, :not_found}
    end
  end

  test "both reads exit when the ledger is not running" do
    missing = :"missing_ledger_#{System.unique_integer([:positive])}"

    assert {:noproc, _call} = catch_exit(Mead.usage(ledger: missing))
    assert {:noproc, _call} = catch_exit(Mead.session_usage("anyone", missing))
  end
end
