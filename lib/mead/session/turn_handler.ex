defmodule Mead.Session.TurnHandler do
  @moduledoc """
  Behaviour for the code that produces the output of a turn.

  A handler receives the turns recorded before the current one, the input of the current turn,
  and the options for the turn: the ones given to `Mead.submit_turn/3` (for example
  `route: :cloud`) plus `session_id`, which the server adds and a caller can never set. It runs
  in an isolated task, so raising, exiting, or running too long never takes the session down.
  """

  alias Mead.Session.Turn

  @callback handle_turn(history :: [Turn.t()], input :: term(), options :: keyword()) ::
              {:ok, output :: term()} | {:error, reason :: term()}
end
