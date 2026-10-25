defmodule Mead.Session.Store do
  @moduledoc """
  Keeps the turns of each conversation in one append-only file per session.

  A file is a sequence of records, `[4-byte length][4-byte CRC32][term_to_binary payload]`, each
  the encoding of one event: `{:append, turn}` when a turn starts, `{:replace_last, turn}` when
  the newest turn is closed, and `:interrupt` when every turn still in progress became
  interrupted. Replaying the events in order rebuilds the list the history agent held.

  A last record that is cut short or fails its checksum is what a crash during a write leaves,
  so it is dropped with a warning. Damage anywhere else is `:corrupt_history`: a conversation
  with a hole in the middle is worse than no conversation. The directory is single-writer.

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

  alias Mead.Session.Turn

  @session_id_shape ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

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

  @doc "Appends one event to the file of a session, creating the directory and file on first use."
  @spec append(String.t(), String.t(), event()) :: :ok | {:error, term()}
  def append(directory, session_id, event) do
    with :ok <- check_session_id(session_id),
         :ok <- File.mkdir_p(directory) do
      path = path(directory, session_id)
      created = not File.exists?(path)

      with {:ok, device} <- File.open(path, [:append, :binary]) do
        outcome = write_record(device, event)
        File.close(device)
        if created, do: File.chmod(path, 0o600)
        outcome
      end
    end
  end

  defp write_record(device, event) do
    with :ok <- IO.binwrite(device, encode(event)), do: :file.sync(device)
  end

  defp encode(event) do
    payload = :erlang.term_to_binary(event)
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  @doc "Returns the turns of a session in chronological order."
  @spec load(String.t(), String.t()) ::
          {:ok, [Turn.t()]} | {:error, :not_found | :corrupt_history | {:persistence, term()}}
  def load(directory, session_id) do
    with :ok <- valid_or_missing(session_id),
         {:ok, binary} <- read(path(directory, session_id)) do
      replay(binary, [], session_id)
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

  defp replay(<<>>, turns, _session_id), do: {:ok, Enum.reverse(turns)}

  defp replay(
         <<size::32, checksum::32, payload::binary-size(size), remaining::binary>>,
         turns,
         session_id
       ) do
    cond do
      :erlang.crc32(payload) == checksum ->
        with {:ok, event} <- decode(payload),
             {:ok, turns} <- apply_event(event, turns) do
          replay(remaining, turns, session_id)
        end

      remaining == <<>> ->
        torn_tail(turns, session_id)

      true ->
        {:error, :corrupt_history}
    end
  end

  defp replay(_incomplete, turns, session_id), do: torn_tail(turns, session_id)

  defp torn_tail(turns, session_id) do
    Logger.warning("dropped an incomplete last record of the history of session #{session_id}")
    {:ok, Enum.reverse(turns)}
  end

  defp decode(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :corrupt_history}
  end

  defp apply_event({:append, %Turn{} = turn}, turns), do: {:ok, [turn | turns]}

  defp apply_event({:replace_last, %Turn{} = turn}, [_newest | older]),
    do: {:ok, [turn | older]}

  defp apply_event(:interrupt, turns), do: {:ok, Enum.map(turns, &Turn.interrupt/1)}
  defp apply_event(_other, _turns), do: {:error, :corrupt_history}

  @doc "Returns true when a file exists for the session."
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(directory, session_id) do
    valid_session_id?(session_id) and File.exists?(path(directory, session_id))
  end

  @doc "Removes the file of a session; a missing file or an invalid id is not an error."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(directory, session_id) do
    if valid_session_id?(session_id) do
      case File.rm(path(directory, session_id)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
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
