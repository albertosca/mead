defmodule Mead.Session.Turn do
  @moduledoc """
  One exchange in a conversation: the input, the output once known, and how it ended.

  `client_turn_id` is the caller's idempotency key, or `nil`; see `Mead.Session.Server`.
  """

  @type status :: :in_progress | :ok | :failed | :timeout | :interrupted

  @type t :: %__MODULE__{
          input: term(),
          output: term(),
          status: status(),
          started_at: DateTime.t(),
          client_turn_id: String.t() | nil
        }

  @enforce_keys [:input, :status, :started_at]
  defstruct [:input, :output, :status, :started_at, :client_turn_id]

  @doc """
  Builds a turn that has just started and has no output yet, under the caller's idempotency key
  when there is one.
  """
  @spec start(term(), String.t() | nil) :: t()
  def start(input, client_turn_id \\ nil) do
    %__MODULE__{
      input: input,
      status: :in_progress,
      started_at: DateTime.utc_now(),
      client_turn_id: client_turn_id
    }
  end

  @doc "Closes a turn with its final status and, when there is one, its output."
  @spec finish(t(), status(), term()) :: t()
  def finish(%__MODULE__{} = turn, status, output \\ nil) do
    %{turn | status: status, output: output}
  end

  @doc "Marks a turn that was still in progress as interrupted; any other turn is unchanged."
  @spec interrupt(t()) :: t()
  def interrupt(%__MODULE__{status: :in_progress} = turn),
    do: finish(turn, :interrupted, turn.output)

  def interrupt(%__MODULE__{} = turn), do: turn
end
