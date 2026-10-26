defmodule Mead.MCP.Server.ToolsUsageTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Server.Tools

  @context %{allow_effect: false}

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  defp unique_session, do: "usage-tool-#{System.unique_integer([:positive])}"

  defp emit(session_id, overrides \\ %{}) do
    metadata =
      Map.merge(
        %{
          route: :cloud,
          route_source: :classified,
          provider: Mead.Test.FakeProvider,
          status: :ok,
          session_id: session_id
        },
        overrides
      )

    measurements = %{
      duration: System.convert_time_unit(7, :millisecond, :native),
      input_tokens: 5,
      output_tokens: 3
    }

    :telemetry.execute([:mead, :router, :route], measurements, metadata)
  end

  defp usage(arguments \\ %{}) do
    {:ok, result} = Tools.call("usage", arguments, @context)
    result
  end

  test "the definition describes both forms and bounds recent" do
    definition = Enum.find(Tools.definitions(), &(&1["name"] == "usage"))

    assert definition["inputSchema"]["type"] == "object"
    assert definition["inputSchema"]["properties"]["session_id"]["type"] == "string"
    assert %{"minimum" => 0, "maximum" => 100} = definition["inputSchema"]["properties"]["recent"]
    refute Map.has_key?(definition["inputSchema"], "required")
  end

  describe "for one session" do
    test "returns the counters of the session" do
      session_id = unique_session()
      emit(session_id)
      emit(session_id, %{status: :error})

      result = usage(%{"session_id" => session_id})

      assert result["isError"] == false

      assert JSON.decode!(text(result)) == %{
               "session_id" => session_id,
               "turns" => 2,
               "failures" => 1,
               "input_tokens" => 10,
               "output_tokens" => 6,
               "duration_ms" => 14
             }
    end

    test "an unknown session is an error result" do
      result = usage(%{"session_id" => unique_session()})

      assert result["isError"] == true
      assert text(result) == "unknown session or no turn counted yet"
    end

    test "a session id that is not a string is invalid params" do
      for invalid <- [123, nil, ["a"]] do
        assert {:error, {:invalid_params, "session_id must be a string"}} =
                 Tools.call("usage", %{"session_id" => invalid}, @context)
      end
    end

    test "ignores recent" do
      session_id = unique_session()
      emit(session_id)

      assert %{"turns" => 1} =
               JSON.decode!(text(usage(%{"session_id" => session_id, "recent" => 0})))
    end
  end

  describe "for the whole ledger" do
    test "has the totals with dropped, the routes and the recent turns as plain JSON" do
      session_id = unique_session()
      emit(session_id)
      emit(nil, %{route: :local, provider: Mead.Test.OtherProvider})

      result = usage(%{"recent" => 100})
      assert result["isError"] == false
      decoded = JSON.decode!(text(result))

      assert Map.keys(decoded) |> Enum.sort() == ["recent", "routes", "totals"]

      assert Map.keys(decoded["totals"]) |> Enum.sort() ==
               ["dropped", "duration_ms", "failures", "input_tokens", "output_tokens", "turns"]

      assert %{"route" => "cloud", "provider" => "Mead.Test.FakeProvider", "turns" => turns} =
               Enum.find(decoded["routes"], &(&1["provider"] == "Mead.Test.FakeProvider"))

      assert turns >= 1

      assert %{
               "route" => "cloud",
               "route_source" => "classified",
               "status" => "ok",
               "at" => timestamp
             } =
               entry = Enum.find(decoded["recent"], &(&1["session_id"] == session_id))

      assert entry["provider"] == "Mead.Test.FakeProvider"
      assert entry["input_tokens"] == 5
      assert entry["output_tokens"] == 3
      assert entry["duration_ms"] == 7
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(timestamp)

      assert Enum.any?(
               decoded["recent"],
               &(&1["session_id"] == nil and &1["provider"] == "Mead.Test.OtherProvider")
             )
    end

    test "recent defaults to twenty and zero asks for none" do
      for _index <- 1..25, do: emit(unique_session())

      assert length(JSON.decode!(text(usage()))["recent"]) == 20
      assert JSON.decode!(text(usage(%{"recent" => 0})))["recent"] == []
      assert length(JSON.decode!(text(usage(%{"recent" => 3})))["recent"]) == 3
    end

    test "a recent outside 0 to 100 or not an integer is invalid params" do
      for invalid <- [-1, 101, 1.5, "5", nil] do
        assert {:error, {:invalid_params, _message}} =
                 Tools.call("usage", %{"recent" => invalid}, @context)
      end
    end
  end
end
