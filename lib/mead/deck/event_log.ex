defmodule Mead.Deck.EventLog do
  @moduledoc """
  The append-only log of the sequenced events of one deck session, one file `<id>.events` per
  session beside the session history, on the same `Mead.Session.Record` framing (length and
  checksum per record, a torn last record cut on open).

  The value is plain data: events are held in memory, newest first, so `read_after/2` never
  touches the disk, and every `append/2` opens the file, writes, syncs and closes it, the way
  `Mead.Session.Store.append/3` does. The whole log is read on `open/2`; that is a documented
  limit until the log gets rotation.

  With a `nil` directory the log lives in memory only, for sessions that have no storage.
  Sequences must strictly increase; an event that does not carry a larger sequence than the last
  one is refused before anything is written.
  """

  alias Mead.Session.Record
  alias Mead.Session.Store

  defstruct [:path, events: [], last_sequence: 0]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          events: [map()],
          last_sequence: non_neg_integer()
        }

  @spec open(String.t() | nil, term()) ::
          {:ok, t()} | {:error, :invalid_session_id | :corrupt | term()}
  def open(directory, session_id) do
    if Store.valid_session_id?(session_id) do
      load(directory, session_id)
    else
      {:error, :invalid_session_id}
    end
  end

  defp load(nil, _session_id), do: {:ok, %__MODULE__{}}

  defp load(directory, session_id) do
    path = path(directory, session_id)

    case File.read(path) do
      {:ok, binary} -> recover(path, binary)
      {:error, :enoent} -> {:ok, %__MODULE__{path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover(path, binary) do
    with {:ok, events, valid_size, _tail} <- Record.scan(binary),
         :ok <- cut_tail(path, valid_size, byte_size(binary)) do
      {:ok,
       %__MODULE__{
         path: path,
         events: Enum.reverse(events),
         last_sequence: last_sequence_of(events)
       }}
    end
  end

  defp cut_tail(_path, size, size), do: :ok
  defp cut_tail(path, valid_size, _file_size), do: Record.truncate(path, valid_size)

  defp last_sequence_of([]), do: 0
  defp last_sequence_of(events), do: events |> List.last() |> Map.fetch!("sequence")

  @doc """
  Appends `event`. With `sync: false` the file is written and closed but not forced to disk, for
  the many small events (streamed text) whose loss in a power cut costs nothing the next synced
  event does not make up for: that sync flushes everything written before it.
  """
  @spec append(t(), map(), keyword()) :: {:ok, t()} | {:error, :out_of_order | term()}
  def append(log, event, options \\ [])

  def append(%__MODULE__{last_sequence: last} = log, %{"sequence" => sequence} = event, options)
      when is_integer(sequence) and sequence > last do
    with :ok <- write(log.path, event, Keyword.get(options, :sync, true)) do
      {:ok, %{log | events: [event | log.events], last_sequence: sequence}}
    end
  end

  def append(%__MODULE__{}, _event, _options), do: {:error, :out_of_order}

  defp write(nil, _event, _sync), do: :ok

  defp write(path, event, sync) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Record.create_private(path),
         {:ok, %File.Stat{size: size_before}} <- File.stat(path),
         {:ok, device} <- File.open(path, [:append, :binary]) do
      outcome =
        with :ok <- IO.binwrite(device, Record.encode(event)),
             do: if(sync, do: :file.sync(device), else: :ok)

      File.close(device)
      if outcome != :ok, do: Record.truncate(path, size_before)
      outcome
    end
  end

  @spec read_after(t(), non_neg_integer()) :: [map()]
  def read_after(%__MODULE__{events: events}, sequence) do
    events
    |> Enum.take_while(&(&1["sequence"] > sequence))
    |> Enum.reverse()
  end

  @spec last_sequence(t()) :: non_neg_integer()
  def last_sequence(%__MODULE__{last_sequence: last}), do: last

  @doc "Present for symmetry with the file lifecycle; the log holds no open handle."
  @spec close(t()) :: :ok
  def close(%__MODULE__{}), do: :ok

  @doc "Removes the file of a session; a missing file or an invalid id is not an error."
  @spec delete(String.t(), term()) :: :ok | {:error, term()}
  def delete(directory, session_id) do
    if Store.valid_session_id?(session_id) do
      Record.remove_leftover(path(directory, session_id))
    else
      :ok
    end
  end

  defp path(directory, session_id), do: Path.join(directory, session_id <> ".events")
end
