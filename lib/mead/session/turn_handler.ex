defmodule Mead.Session.TurnHandler do
  @moduledoc """
  Behaviour for the code that produces the output of a turn.

  A handler receives the turns recorded before the current one and the input of the current
  turn. It runs in an isolated task, so raising, exiting, or running too long never takes the
  session down.
  """

  alias Mead.Session.Turn

  @callback handle_turn(history :: [Turn.t()], input :: term()) ::
              {:ok, output :: term()} | {:error, reason :: term()}
end
