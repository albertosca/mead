defmodule Mead.Test.ScriptedHandler do
  @moduledoc false

  # A turn handler whose behaviour is chosen by the input, so each test scripts exactly the
  # failure it wants to provoke.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, {:echo, text}, _options), do: {:ok, text}
  def handle_turn(_history, :raise, _options), do: raise("scripted failure")
  def handle_turn(_history, :exit, _options), do: exit(:scripted_exit)
  def handle_turn(_history, {:error, reason}, _options), do: {:error, reason}
  def handle_turn(_history, :bad_return, _options), do: :unexpected

  # Reports the options it received, so a test can see what reached the handler.
  def handle_turn(_history, {:report_options, test_pid}, options) do
    send(test_pid, {:handler_options, options})
    {:ok, :reported}
  end

  # Announces its pid to the test, then waits to be released (or killed, or timed out).
  def handle_turn(_history, {:block, test_pid}, _options) do
    send(test_pid, {:handler_started, self()})

    receive do
      :release -> {:ok, :released}
    end
  end
end
