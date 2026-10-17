defmodule Mead.Test.ScriptedHandler do
  @moduledoc false

  # A turn handler whose behaviour is chosen by the input, so each test scripts exactly the
  # failure it wants to provoke.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, {:echo, text}), do: {:ok, text}
  def handle_turn(_history, :raise), do: raise("scripted failure")
  def handle_turn(_history, :exit), do: exit(:scripted_exit)
  def handle_turn(_history, {:error, reason}), do: {:error, reason}
  def handle_turn(_history, :bad_return), do: :unexpected

  # Announces its pid to the test, then waits to be released (or killed, or timed out).
  def handle_turn(_history, {:block, test_pid}) do
    send(test_pid, {:handler_started, self()})

    receive do
      :release -> {:ok, :released}
    end
  end
end
