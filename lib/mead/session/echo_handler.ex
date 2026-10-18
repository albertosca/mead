defmodule Mead.Session.EchoHandler do
  @moduledoc """
  Provisional default handler that answers every turn with its own input.

  It exists only so a turn has something to run until the model router replaces it.
  """

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, input, _options), do: {:ok, input}
end
