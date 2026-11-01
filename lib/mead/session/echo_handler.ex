defmodule Mead.Session.EchoHandler do
  @moduledoc """
  Provisional default handler that answers every turn with its own input.

  It exists only so a turn has something to run until the model router replaces it.
  """

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, input, _options), do: {:ok, input}

  # Answering is pure, so a continued turn just answers again.
  @impl true
  def resume_turn(history, input, _steps, options), do: handle_turn(history, input, options)
end
