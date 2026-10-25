defmodule Mead.Session.Store do
  @moduledoc """
  Keeps the turns of each conversation in one append-only file per session.

  A file is a sequence of records framed by `Mead.Session.Record`, each the encoding of one event: `{:append, turn}` when a turn starts, `{:replace_last, turn}` when the newest turn is closed, and `:interrupt` when every turn still in progress became interrupted. Replaying the events in order rebuilds the list the history agent held.

  A last record that is cut short or fails its payload checksum is what a crash during a write
  leaves, so it is dropped with a warning. The length has a checksum of its own, so a flipped bit
  in a header cannot pass for a cut write: damage anywhere else is `:corrupt_history`, because a
  conversation with a hole in the middle is worse than no conversation. `load/2` only reads;
  `recover/2` also cuts the dropped tail off the file, which a session must do before it writes
  again, or its next record would land behind the garbage and make the whole file unreadable. A
  write that fails is rolled back to the size the file had before it, for the same reason. The
  directory is single-writer.

  `compact/3` rewrites a file as one `{:append, turn}` per turn, through a synced `<id>.log.tmp`
  renamed over the log, so a crash leaves the old file or the new one and `load/2` answers the
  same turns before and after.

  Payloads are decoded without `:safe`. A failed turn keeps its reason as output, and that reason
  can hold an exception or an atom from a module a freshly booted node has not loaded yet, which
  safe decoding refuses: a conversation with a failure in it could not be resumed. The files are
  written by this node, are private to its owner, and are guarded by a checksum; decoding never
  runs code, and whoever can write the directory can already do far worse. Do not point the
  directory at data from a source you do not trust.

  A session id becomes a file name, so it is accepted only in the shape `Mead.UUID.generate/0`
  produces, and checked before any path is built.
  """

  require Logger

  alias Mead.Session.Record
  alias Mead.Session.Turn

  @session_id_shape ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @default_compact_after_bytes 1_048_576
  @default_ledger_journal_max_bytes 1_048_576

  @type event :: {:append, Turn.t()} | {:replace_last, Turn.t()} | :interrupt

  @doc "Returns the configured storage directory, or `nil` when persistence is off."
  @spec directory() :: String.t() | nil
  def directory do
    case Application.get_env(:mead, :storage) do
      nil ->
        nil

      storage when is_list(storage) ->
        validate_directory(Keyword.get(storage, :directory))

      other ->
        raise ArgumentError,
              "config :mead, :storage must be a keyword list, got: #{inspect(other)}"
    end
  end

  defp validate_directory(nil), do: nil
  defp validate_directory(directory) when is_binary(directory) and directory != "", do: directory

  defp validate_directory(other) do
    raise ArgumentError,
          "config :mead, :storage, directory must be a non-empty string, got: #{inspect(other)}"
  end

  @doc """
  Returns the size in bytes a live session's file may reach before it is compacted.

  Defaults to one mebibyte; `config :mead, :storage, compact_after_bytes:` sets it. Anything but
  a positive integer raises `ArgumentError`, rather than quietly never compacting.
  """
  @spec compact_after_bytes() :: pos_integer()
  def compact_after_bytes do
    case Application.get_env(:mead, :storage) do
      nil ->
        @default_compact_after_bytes

      storage when is_list(storage) ->
        storage
        |> Keyword.get(:compact_after_bytes, @default_compact_after_bytes)
        |> validate_compact_after()

      other ->
        raise ArgumentError,
              "config :mead, :storage must be a keyword list, got: #{inspect(other)}"
    end
  end

  defp validate_compact_after(bytes) when is_integer(bytes) and bytes > 0, do: bytes

  defp validate_compact_after(other) do
    raise ArgumentError,
          "config :mead, :storage, compact_after_bytes must be a positive integer, got: #{inspect(other)}"
  end

  @doc """
  Returns the size in bytes the ledger journal may reach before it is rewritten as a checkpoint.

  Defaults to one mebibyte; `config :mead, :storage, ledger_journal_max_bytes:` sets it, and `nil` means the default. Anything but a positive integer raises `ArgumentError`.
  """
  @spec ledger_journal_max_bytes() :: pos_integer()
  def ledger_journal_max_bytes do
    case Application.get_env(:mead, :storage) do
      nil ->
        @default_ledger_journal_max_bytes

      storage when is_list(storage) ->
        case Keyword.get(storage, :ledger_journal_max_bytes) do
          nil -> @default_ledger_journal_max_bytes
          bytes -> validate_ledger_journal_max_bytes(bytes)
        end

      other ->
        raise ArgumentError,
              "config :mead, :storage must be a keyword list, got: #{inspect(other)}"
    end
  end

  defp validate_ledger_journal_max_bytes(bytes) when is_integer(bytes) and bytes > 0, do: bytes

  defp validate_ledger_journal_max_bytes(other) do
    raise ArgumentError,
          "config :mead, :storage, ledger_journal_max_bytes must be a positive integer, got: #{inspect(other)}"
  end

  @doc "Appends one event to the file of a session, creating the directory and file on first use."
  @spec append(String.t(), String.t(), event()) :: :ok | {:error, term()}
  def append(directory, session_id, event) do
    with :ok <- check_session_id(session_id),
         :ok <- File.mkdir_p(directory),
         path = path(directory, session_id),
         :ok <- Record.create_private(path),
         {:ok, %File.Stat{size: size_before}} <- File.stat(path),
         {:ok, device} <- File.open(path, [:append, :binary]) do
      outcome = write_record(device, event)
      File.close(device)
      if outcome != :ok, do: rollback(path, size_before)
      outcome
    end
  end

  @doc false
  @spec rollback(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  defdelegate rollback(path, size), to: Record, as: :truncate

  defp write_record(device, event) do
    with :ok <- IO.binwrite(device, Record.encode(event)), do: :file.sync(device)
  end

  @doc "Returns the turns of a session in chronological order, without touching the file."
  @spec load(String.t(), String.t()) ::
          {:ok, [Turn.t()]} | {:error, :not_found | :corrupt_history | {:persistence, term()}}
  def load(directory, session_id) do
    with :ok <- valid_or_missing(session_id),
         {:ok, binary} <- read(path(directory, session_id)),
         {:ok, turns, _valid_size} <- replay(binary, session_id) do
      {:ok, turns}
    end
  end

  @doc """
  Like `load/2`, and cuts a torn last record off the file so that later appends follow the last
  complete record.
  """
  @spec recover(String.t(), String.t()) ::
          {:ok, [Turn.t()]} | {:error, :not_found | :corrupt_history | {:persistence, term()}}
  def recover(directory, session_id) do
    with :ok <- valid_or_missing(session_id),
         path = path(directory, session_id),
         {:ok, binary} <- read(path),
         {:ok, turns, valid_size} <- replay(binary, session_id),
         :ok <- cut_tail(path, valid_size, byte_size(binary)) do
      {:ok, turns}
    end
  end

  defp cut_tail(_path, size, size), do: :ok

  defp cut_tail(path, valid_size, _file_size) do
    case rollback(path, valid_size) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  defp valid_or_missing(session_id) do
    if valid_session_id?(session_id), do: :ok, else: {:error, :not_found}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  defp replay(binary, session_id) do
    with {:ok, events, valid_size, tail} <- Record.scan(binary),
         {:ok, turns} <- apply_events(events) do
      if tail == :torn do
        Logger.warning(
          "dropped an incomplete last record of the history of session #{session_id}"
        )
      end

      {:ok, turns, valid_size}
    else
      {:error, :corrupt} -> {:error, :corrupt_history}
      {:error, :corrupt_history} = error -> error
    end
  end

  defp apply_events(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, turns} ->
      case apply_event(event, turns) do
        {:ok, turns} -> {:cont, {:ok, turns}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> chronological()
  end

  defp chronological({:ok, turns}), do: {:ok, Enum.reverse(turns)}
  defp chronological({:error, _reason} = error), do: error

  defp apply_event({:append, %Turn{} = turn}, turns), do: {:ok, [turn | turns]}

  defp apply_event({:replace_last, %Turn{} = turn}, [_newest | older]),
    do: {:ok, [turn | older]}

  defp apply_event(:interrupt, turns), do: {:ok, Enum.map(turns, &Turn.interrupt/1)}
  defp apply_event(_other, _turns), do: {:error, :corrupt_history}

  @doc """
  Lists the stored sessions, newest first, as maps with the `:session_id` and the `:updated_at` of
  its file.

  Only names and file times are read, never the content, so the cost does not grow with the
  length of the conversations. Anything in the directory that is not a session file is ignored,
  and a damaged file is listed like any other: only `recover/2` reads it. A directory that does
  not exist yet holds no sessions.
  """
  @spec list(String.t()) ::
          {:ok, [%{session_id: String.t(), updated_at: DateTime.t()}]}
          | {:error, {:persistence, term()}}
  def list(directory) do
    case File.ls(directory) do
      {:ok, names} -> {:ok, names |> Enum.flat_map(&list_entry(directory, &1)) |> newest_first()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  defp list_entry(directory, name) do
    with ".log" <- Path.extname(name),
         session_id = Path.rootname(name),
         true <- valid_session_id?(session_id),
         {:ok, %File.Stat{type: :regular, mtime: mtime}} <-
           File.stat(Path.join(directory, name), time: :posix) do
      [%{session_id: session_id, updated_at: DateTime.from_unix!(mtime)}]
    else
      _not_a_session_file -> []
    end
  end

  defp newest_first(entries) do
    Enum.sort_by(entries, &{DateTime.to_unix(&1.updated_at), &1.session_id}, :desc)
  end

  @doc "Returns true when a file exists for the session."
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(directory, session_id) do
    valid_session_id?(session_id) and File.exists?(path(directory, session_id))
  end

  @doc "Returns the size in bytes of the file of a session."
  @spec size(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | {:persistence, term()}}
  def size(directory, session_id) do
    with :ok <- valid_or_missing(session_id) do
      case File.stat(path(directory, session_id)) do
        {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
        {:ok, _not_a_file} -> {:error, :not_found}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:persistence, reason}}
      end
    end
  end

  @doc """
  Rewrites the file of a session as one `{:append, turn}` record per turn, given in
  chronological order, and returns the size of the file before and after.

  The file is replaced only when the new form is smaller, so a file that is already compact is
  left alone and both sizes are the current one. The replacement is written to `<id>.log.tmp`,
  synced, and renamed over the log, so a crash leaves the old file or the new one. A failure
  leaves the log as it was and removes the temporary file. A file that does not exist is
  `{:error, :not_found}`: compaction never creates a conversation.
  """
  @spec compact(String.t(), String.t(), [Turn.t()]) ::
          {:ok, %{bytes_before: non_neg_integer(), bytes_after: non_neg_integer()}}
          | {:error, :not_found | {:persistence, term()}}
  def compact(directory, session_id, turns) do
    with {:ok, bytes_before} <- size(directory, session_id) do
      canonical = turns |> Enum.map(&Record.encode({:append, &1})) |> IO.iodata_to_binary()
      bytes_after = byte_size(canonical)

      if bytes_after < bytes_before do
        with :ok <- replace(directory, path(directory, session_id), canonical) do
          {:ok, %{bytes_before: bytes_before, bytes_after: bytes_after}}
        end
      else
        {:ok, %{bytes_before: bytes_before, bytes_after: bytes_before}}
      end
    end
  end

  defp replace(directory, path, canonical) do
    temporary = path <> ".tmp"

    result =
      with :ok <- Record.remove_leftover(temporary),
           :ok <- Record.create_private(temporary),
           :ok <- Record.write_synced(temporary, canonical),
           :ok <- File.rename(temporary, path) do
        Record.sync_directory(directory)
      end

    File.rm(temporary)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  @doc """
  Removes the file of a session, and the temporary file a crashed compaction may have left beside
  it; a missing file or an invalid id is not an error.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(directory, session_id) do
    if valid_session_id?(session_id) do
      log = path(directory, session_id)

      with :ok <- Record.remove_leftover(log <> ".tmp") do
        Record.remove_leftover(log)
      end
    else
      :ok
    end
  end

  defp check_session_id(session_id) do
    if valid_session_id?(session_id), do: :ok, else: {:error, :invalid_session_id}
  end

  defp valid_session_id?(session_id) do
    is_binary(session_id) and Regex.match?(@session_id_shape, session_id)
  end

  defp path(directory, session_id), do: Path.join(directory, session_id <> ".log")
end
