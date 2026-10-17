defmodule Mead.Session.Turn do
  @moduledoc """
  One exchange in a conversation: the input, the output once known, and how it ended.
  """

  @type status :: :in_progress | :ok | :failed | :timeout | :interrupted

  @type t :: %__MODULE__{
          input: term(),
          output: term(),
          status: status(),
          started_at: DateTime.t()
        }

  @enforce_keys [:input, :status, :started_at]
  defstruct [:input, :output, :status, :started_at]

  @doc "Builds a turn that has just started and has no output yet."
  @spec start(term()) :: t()
  def start(input) do
    %__MODULE__{input: input, status: :in_progress, started_at: DateTime.utc_now()}
  end

  @doc "Closes a turn with its final status and, when there is one, its output."
  @spec finish(t(), status(), term()) :: t()
  def finish(%__MODULE__{} = turn, status, output \\ nil) do
    %{turn | status: status, output: output}
  end
end
