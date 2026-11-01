defmodule Mead.Session.TurnHandler do
  @moduledoc """
  Behaviour for the code that produces the output of a turn.

  A handler receives the turns recorded before the current one, the input of the current turn,
  and the options for the turn: the ones given to `Mead.submit_turn/3` (for example
  `route: :cloud`) plus `session_id` and `checkpoint`, which the server adds and a caller can never
  set. It runs in an isolated task, so raising, exiting, or running too long never takes the
  session down.

  `checkpoint` is a one-argument function that records a step of the turn (any term the handler
  chooses) and answers `:ok` or `{:error, reason}`. `resume_turn/4` continues a turn that a crash
  or a stop cut short: it gets the steps recorded so far, in order, and must not redo their work.
  It is required, and `Mead.start_session/1` refuses a handler without it, so every turn can
  continue. A handler that records no steps can resume by calling `handle_turn/3` again, which is
  only safe when running the turn twice is; otherwise returning `{:error, :not_resumable}` ends
  the cut turn as failed and repeats nothing. A handler that records a step must stop when the write
  fails, because nothing it does after that can be continued.
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
end
