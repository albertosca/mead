defmodule Mead.Session.History do
  @moduledoc """
  Keeps the turns of one conversation, and writes them through `Mead.Session.Store` when the
  session has a storage directory.

  The state holds the turns with the newest first and the directory, or `nil` when persistence
  is off. Only `append/2` is write-first: a turn that cannot be recorded is refused and memory is
  left untouched, so a conversation never accepts a turn it would forget. `update_last/2` and
  `mark_interrupted/1` always change memory and then try to write, because the caller already
  holds the answer; a closed turn that never reached the disk comes back after a restart as an
  interrupted one, which is accurate.

  When the file passes `:compact_after_bytes` the history rewrites it from memory with
  `Mead.Session.Store.compact/3`; a failed rewrite is logged and never fails a write.

  The agent is started before the session server, so a server crash leaves the history untouched.
  """

  use Agent

  require Logger

  alias Mead.Session
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @type persistence_error :: {:error, {:persistence, term()}}

  @doc """
  Starts the history for `options[:session_id]`, registered under `Mead.Registry`.

  `:directory` is where to write (or `nil`), `:resume` is a list of turns in chronological
  order to start from, and `:compact_after_bytes` is the file size from which the file is
  compacted (absent means never).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    directory = Keyword.get(options, :directory)
    resume = Keyword.get(options, :resume, [])
    compact_after_bytes = Keyword.get(options, :compact_after_bytes)

    Agent.start_link(
      fn ->
        %{
          turns: Enum.reverse(initial_turns(directory, session_id, resume)),
          directory: directory,
          compact_after_bytes: compact_after_bytes,
          floor: stored_size(directory, session_id)
        }
      end,
      name: Session.via(session_id, :history)
    )
  end

  defp stored_size(nil, _session_id), do: 0

  defp stored_size(directory, session_id) do
    case Store.size(directory, session_id) do
      {:ok, size} -> size
      {:error, _reason} -> 0
    end
  end

  # The file is the truth. A history that restarts after a crash must not fall back to the turns
  # it was resumed with, which the file has long outgrown; `resume` is the answer only when there
  # is nothing stored to read (no directory, or nothing written yet).
  defp initial_turns(nil, _session_id, resume), do: resume

  defp initial_turns(directory, session_id, resume) do
    case Store.load(directory, session_id) do
      {:ok, turns} -> turns
      {:error, _reason} -> resume
    end
  end

  @doc "Records a turn as the newest one, or refuses it when it cannot be written."
  @spec append(String.t(), Turn.t()) :: :ok | persistence_error()
  def append(session_id, %Turn{} = turn) do
    Agent.get_and_update(Session.via(session_id, :history), fn state ->
      case persist(state, session_id, {:append, turn}) do
        :ok -> {:ok, compact_if_due(%{state | turns: [turn | state.turns]}, session_id)}
        error -> {error, state}
      end
    end)
  end

  @doc "Returns all turns in chronological order."
  @spec all(String.t()) :: [Turn.t()]
  def all(session_id) do
    session_id
    |> Session.via(:history)
    |> Agent.get(&Enum.reverse(&1.turns))
  end

  @doc """
  Replaces the newest turn with the result of `function` applied to it.

  Memory changes even when the write fails; the error tells the caller the disk is behind.
  """
  @spec update_last(String.t(), (Turn.t() -> Turn.t())) :: :ok | persistence_error()
  def update_last(session_id, function) do
    Agent.get_and_update(Session.via(session_id, :history), fn
      %{turns: [newest | older]} = state ->
        closed = function.(newest)
        state = %{state | turns: [closed | older]}

        case persist(state, session_id, {:replace_last, closed}) do
          :ok -> {:ok, compact_if_due(state, session_id)}
          error -> {error, state}
        end

      %{turns: []} = state ->
        {:ok, state}
    end)
  end

  @doc "Marks every turn still in progress as interrupted, and records that when there was one."
  @spec mark_interrupted(String.t()) :: :ok | persistence_error()
  def mark_interrupted(session_id) do
    Agent.get_and_update(Session.via(session_id, :history), fn state ->
      if Enum.any?(state.turns, &(&1.status == :in_progress)) do
        state = %{state | turns: Enum.map(state.turns, &Turn.interrupt/1)}

        case persist(state, session_id, :interrupt) do
          :ok -> {:ok, compact_if_due(state, session_id)}
          error -> {error, state}
        end
      else
        {:ok, state}
      end
    end)
  end

  @doc """
  Rewrites the file of the session as one record per turn, from the turns in memory.

  Returns the sizes before and after, `{:error, :not_found}` when there is no storage or no file
  yet, or the persistence error; the original file is untouched on an error.
  """
  @spec compact(String.t()) ::
          {:ok, %{bytes_before: non_neg_integer(), bytes_after: non_neg_integer()}}
          | {:error, :not_found | {:persistence, term()}}
  def compact(session_id) do
    Agent.get_and_update(Session.via(session_id, :history), &compact_now(&1, session_id))
  end

  defp compact_now(%{directory: nil} = state, _session_id), do: {{:error, :not_found}, state}

  defp compact_now(state, session_id) do
    case Store.compact(state.directory, session_id, Enum.reverse(state.turns)) do
      {:ok, %{bytes_after: bytes_after}} = result ->
        {result, %{state | floor: bytes_after}}

      {:error, reason} = error ->
        Logger.warning(
          "could not compact the history of session #{session_id}: #{inspect(reason)}"
        )

        {error, %{state | floor: stored_size(state.directory, session_id)}}
    end
  end

  # Compacts once the file is at least `compact_after_bytes` and half again as large as it was
  # right after the last compaction. Without the second condition a file whose compact form
  # already passes the threshold would be rewritten on every turn.
  defp compact_if_due(%{directory: nil} = state, _session_id), do: state
  defp compact_if_due(%{compact_after_bytes: nil} = state, _session_id), do: state

  defp compact_if_due(state, session_id) do
    with {:ok, size} <- Store.size(state.directory, session_id),
         true <- size >= state.compact_after_bytes and size * 2 >= state.floor * 3 do
      {_result, state} = compact_now(state, session_id)
      state
    else
      _not_due -> state
    end
  end

  defp persist(%{directory: nil}, _session_id, _event), do: :ok

  defp persist(%{directory: directory}, session_id, event) do
    case Store.append(directory, session_id, event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end
end
