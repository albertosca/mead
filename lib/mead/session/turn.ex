defmodule Mead.Session.Turn do
  @moduledoc """
  One exchange in a conversation: the input, the output once known, and how it ended.

  `client_turn_id` is the caller's idempotency key, or `nil`; see `Mead.Session.Server`.

  A turn in progress also carries what it needs to continue after a restart: `steps`, the checkpoint its handler recorded so far, in order (an opaque term per step, cleared when the turn closes); `resumes`, how many times it was continued; `crash_resumes`, how many of those continued an attempt cut under the same infrastructure, so by the session itself; `generation`, a fingerprint of the infrastructure the current attempt runs under (`Mead.Session.Generation`), `nil` when none was recorded; and `turn_options`, the options its handler needs to continue (`%{route: route, tools: tools | nil, interactive: boolean}`, never a pid), `%{}` for a turn recorded before this existed, which is never continued.
  """

  @type status :: :in_progress | :ok | :failed | :timeout | :interrupted

  @type t :: %__MODULE__{
          input: term(),
          output: term(),
          status: status(),
          started_at: DateTime.t(),
          client_turn_id: String.t() | nil,
          steps: [term()],
          resumes: non_neg_integer(),
          crash_resumes: non_neg_integer(),
          generation: term(),
          turn_options: map()
        }

  @enforce_keys [:input, :status, :started_at]
  defstruct [
    :input,
    :output,
    :status,
    :started_at,
    :client_turn_id,
    :generation,
    steps: [],
    resumes: 0,
    crash_resumes: 0,
    turn_options: %{}
  ]

  @doc """
  Builds a turn that has just started and has no output yet, under the caller's idempotency key
  when there is one, with the options its handler needs to continue it.
  """
  @spec start(term(), String.t() | nil, map()) :: t()
  def start(input, client_turn_id \\ nil, turn_options \\ %{}) do
    %__MODULE__{
      input: input,
      status: :in_progress,
      started_at: DateTime.utc_now(),
      client_turn_id: client_turn_id,
      turn_options: turn_options
    }
  end

  @doc "Closes a turn with its final status and, when there is one, its output; its steps go."
  @spec finish(t(), status(), term()) :: t()
  def finish(%__MODULE__{} = turn, status, output \\ nil) do
    %{turn | status: status, output: output, steps: []}
  end

  @doc "Marks a turn that was still in progress as interrupted; any other turn is unchanged."
  @spec interrupt(t()) :: t()
  def interrupt(%__MODULE__{status: :in_progress} = turn),
    do: finish(turn, :interrupted, turn.output)

  def interrupt(%__MODULE__{} = turn), do: turn
end
