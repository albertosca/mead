defmodule Mead.Session.TurnHandler do
  @moduledoc """
  Behaviour for the code that produces the output of a turn.

  A handler receives the turns recorded before the current one, the input of the current turn,
  and the options for the turn: the ones given to `Mead.submit_turn/3` (for example
  `route: :cloud`) plus `session_id` and `checkpoint`, which the server adds and a caller can never
  set. It runs in an isolated task, so raising, exiting, or running too long never takes the
  session down.

  `checkpoint` is a one-argument function that records a step of the turn (any term the handler
  chooses) and answers `:ok` or `{:error, reason}`. A handler that also implements the optional
  `resume_turn/4` can continue a turn submitted with a `client_turn_id` that was cut short by a
  crash or a stop: it gets the steps recorded so far, in order, and must not redo their work. A
  handler that records a step must stop when the write fails, because nothing it does after that
  can be continued.
  """

  alias Mead.Session.Turn

  @callback handle_turn(history :: [Turn.t()], input :: term(), options :: keyword()) ::
              {:ok, output :: term()} | {:error, reason :: term()}

  @callback resume_turn(
              history :: [Turn.t()],
              input :: term(),
              steps :: [term()],
              options :: keyword()
            ) :: {:ok, output :: term()} | {:error, reason :: term()}

  @optional_callbacks resume_turn: 4
end
