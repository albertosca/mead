defmodule Mead.MCP.Server.ToolsUsageLedgerDownTest do
  # Stops the ledger of the application, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.MCP.Server.Tools

  setup do
    :ok = Supervisor.terminate_child(Mead.Supervisor, Mead.Ledger)

    on_exit(fn ->
      case Supervisor.restart_child(Mead.Supervisor, Mead.Ledger) do
        {:ok, _pid} -> :ok
        {:error, :running} -> :ok
      end
    end)
  end

  test "both forms answer an error result, not an exit, when the ledger is not running" do
    for arguments <- [%{}, %{"session_id" => "anyone"}] do
      assert {:ok, %{"isError" => true} = result} =
               Tools.call("usage", arguments, %{allow_effect: false})

      assert result["content"] == [%{"type" => "text", "text" => "the ledger is not available"}]
    end
  end
end
