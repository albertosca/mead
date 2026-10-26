defmodule Mead.Ledger.Journal do
  @moduledoc """
  The pure model of the ledger journal: the counter rows, the ring of the last 100 turns and the dropped count that a sequence of journal events adds up to.

  The events are `{:turn, entry}`, with the map the ring holds, `{:forget, session_id}`, `:dropped`, and `{:checkpoint, rows, ring}`, which replaces everything before it with the whole state: every counter row, plus `{:dropped, count}` when it is above zero, and the ring entries oldest first. Replaying the events of a file rebuilds the numbers the ETS tables held. It also serves the rewrite of the file, which is built from the file itself and not from the tables: the tables may already hold an event whose journal record has not been written, and a checkpoint taken from them would count it twice.

  A counter row is `{key, turns, failures, input_tokens, output_tokens, duration_ms}`, where the key is `{:session, id}` or `{:route, route, provider}`.
  """

  @ring_size 100

  defstruct rows: %{}, ring: [], dropped: 0

  @type entry :: map()
  @type counter_row ::
          {term(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}
  @type event ::
          {:turn, entry()}
          | {:forget, String.t()}
          | :dropped
          | {:checkpoint, [counter_row() | {:dropped, pos_integer()}], [entry()]}
  @type t :: %__MODULE__{
          rows: %{term() => counter_row()},
          ring: [entry()],
          dropped: non_neg_integer()
        }

  @doc "An empty model."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "What one turn adds to a counter row: turns, failures, input tokens, output tokens, ms."
  @spec increments(entry()) :: {1, 0 | 1, non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def increments(entry) do
    failures = if entry.status == :ok, do: 0, else: 1
    {1, failures, entry.input_tokens, entry.output_tokens, entry.duration_ms}
  end

  @doc "The `:ets.update_counter/4` operations that add one turn to a counter row."
  @spec operations(entry()) :: [{pos_integer(), non_neg_integer()}]
  def operations(entry) do
    entry
    |> increments()
    |> Tuple.to_list()
    |> Enum.with_index(2)
    |> Enum.map(fn {amount, position} -> {position, amount} end)
  end

  @doc "Adds the events up, or `{:error, :corrupt}` at the first one nobody writes."
  @spec replay([event()]) :: {:ok, t()} | {:error, :corrupt}
  def replay(events) do
    Enum.reduce_while(events, {:ok, new()}, fn event, {:ok, model} ->
      case apply_event(model, event) do
        {:ok, model} -> {:cont, {:ok, model}}
        :error -> {:halt, {:error, :corrupt}}
      end
    end)
  end

  @doc "Applies one event to the model."
  @spec apply_event(t(), event()) :: {:ok, t()} | :error
  def apply_event(model, {:turn, entry}) do
    if entry?(entry) do
      increments = increments(entry)
      keys = [{:route, entry.route, entry.provider} | session_keys(entry.session_id)]
      rows = Enum.reduce(keys, model.rows, &add_row(&2, &1, increments))

      {:ok, %{model | rows: rows, ring: Enum.take([entry | model.ring], @ring_size)}}
    else
      :error
    end
  end

  def apply_event(model, {:forget, session_id}) when is_binary(session_id) do
    {:ok, %{model | rows: Map.delete(model.rows, {:session, session_id})}}
  end

  def apply_event(model, :dropped), do: {:ok, %{model | dropped: model.dropped + 1}}

  def apply_event(_model, {:checkpoint, rows, ring}) when is_list(rows) and is_list(ring) do
    if Enum.all?(rows, &row?/1) and Enum.all?(ring, &entry?/1) do
      restored =
        Enum.reduce(rows, %__MODULE__{ring: Enum.reverse(ring)}, fn
          {:dropped, count}, model -> %{model | dropped: count}
          row, model -> %{model | rows: Map.put(model.rows, elem(row, 0), row)}
        end)

      {:ok, restored}
    else
      :error
    end
  end

  def apply_event(_model, _event), do: :error

  defp entry?(%{
         session_id: session_id,
         route: route,
         provider: provider,
         status: status,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         duration_ms: duration_ms
       }) do
    (is_nil(session_id) or is_binary(session_id)) and is_atom(route) and is_atom(provider) and
      status in [:ok, :error] and counter?(input_tokens) and counter?(output_tokens) and
      counter?(duration_ms)
  end

  defp entry?(_other), do: false

  defp row?({:dropped, count}), do: is_integer(count) and count > 0

  defp row?({key, turns, failures, input_tokens, output_tokens, duration_ms}) do
    row_key?(key) and
      Enum.all?([turns, failures, input_tokens, output_tokens, duration_ms], &counter?/1)
  end

  defp row?(_other), do: false

  defp row_key?({:session, session_id}), do: is_binary(session_id)
  defp row_key?({:route, route, provider}), do: is_atom(route) and is_atom(provider)
  defp row_key?(_other), do: false

  defp counter?(value), do: is_integer(value) and value >= 0

  defp session_keys(nil), do: []
  defp session_keys(session_id), do: [{:session, session_id}]

  defp add_row(rows, key, {turns, failures, input_tokens, output_tokens, duration_ms}) do
    Map.update(rows, key, {key, turns, failures, input_tokens, output_tokens, duration_ms}, fn
      {key, held_turns, held_failures, held_input, held_output, held_duration} ->
        {key, held_turns + turns, held_failures + failures, held_input + input_tokens,
         held_output + output_tokens, held_duration + duration_ms}
    end)
  end

  @doc "The counter rows of the model."
  @spec rows(t()) :: [counter_row()]
  def rows(model), do: Map.values(model.rows)

  @doc "The ring entries, oldest first."
  @spec ring_oldest_first(t()) :: [entry()]
  def ring_oldest_first(model), do: Enum.reverse(model.ring)

  @doc "How many unreadable events the model has seen."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(model), do: model.dropped

  @doc "The checkpoint event that replays to this model."
  @spec checkpoint(t()) :: event()
  def checkpoint(model) do
    dropped_row = if model.dropped > 0, do: [{:dropped, model.dropped}], else: []
    {:checkpoint, rows(model) ++ dropped_row, ring_oldest_first(model)}
  end
end
