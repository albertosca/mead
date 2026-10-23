defmodule Mead.Test.TextHandler do
  @moduledoc false

  # A turn handler chosen by a text input, because MCP clients can only send strings and
  # `Mead.Test.ScriptedHandler` matches on tuples.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, "echo " <> text, _options), do: {:ok, text}
  def handle_turn(_history, "raise", _options), do: raise("scripted failure")
  def handle_turn(_history, "error", _options), do: {:error, :scripted}
  def handle_turn(_history, "binary", _options), do: {:ok, <<255, 254>>}

  def handle_turn(_history, "options", options) do
    {:ok, inspect(Keyword.take(options, [:route, :tools]))}
  end

  # Announces its pid to the test that registered `:mcp_text_handler_test`, then waits to be
  # released (or killed, or timed out).
  def handle_turn(_history, "block", _options) do
    case Process.whereis(:mcp_text_handler_test) do
      nil -> :ok
      test_pid -> send(test_pid, {:handler_started, self()})
    end

    receive do
      :release -> {:ok, "released"}
    end
  end
end
