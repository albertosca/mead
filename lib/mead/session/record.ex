defmodule Mead.Session.Record do
  @moduledoc """
  The record framing shared by the session files and the ledger journal, and the few file
  operations both need.

  A record is `[4-byte length][4-byte CRC32 of the length][4-byte CRC32 of the payload]
  [term_to_binary payload]`. `scan/1` reads a whole file: a last record that is cut short or fails
  its payload checksum is what a crash during a write leaves, so it is a `:torn` tail and the valid
  size stops before it; the length has a checksum of its own, so damage anywhere else, or a
  payload that does not decode, is `{:error, :corrupt}`.

  Payloads are decoded without `:safe`, for the reasons given in `Mead.Session.Store`.
  """

  @header_size 12

  @doc "Frames `term` as one record."
  @spec encode(term()) :: binary()
  def encode(term) do
    payload = :erlang.term_to_binary(term)
    size = byte_size(payload)
    <<size::32, :erlang.crc32(<<size::32>>)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  @doc """
  Reads every record of `binary` and returns the terms, the size of the valid prefix, and whether
  the file ended cleanly or in a torn tail.
  """
  @spec scan(binary()) ::
          {:ok, [term()], non_neg_integer(), :clean | :torn} | {:error, :corrupt}
  def scan(binary), do: scan(binary, 0, [])

  defp scan(<<>>, offset, terms), do: {:ok, Enum.reverse(terms), offset, :clean}

  defp scan(<<size::32, header_checksum::32, checksum::32, rest::binary>>, offset, terms) do
    cond do
      :erlang.crc32(<<size::32>>) != header_checksum ->
        {:error, :corrupt}

      byte_size(rest) < size ->
        {:ok, Enum.reverse(terms), offset, :torn}

      true ->
        <<payload::binary-size(^size), remaining::binary>> = rest
        scan_payload(payload, checksum, remaining, offset, terms)
    end
  end

  defp scan(_incomplete_header, offset, terms), do: {:ok, Enum.reverse(terms), offset, :torn}

  defp scan_payload(payload, checksum, remaining, offset, terms) do
    cond do
      :erlang.crc32(payload) == checksum ->
        case decode(payload) do
          {:ok, term} ->
            scan(remaining, offset + @header_size + byte_size(payload), [term | terms])

          :error ->
            {:error, :corrupt}
        end

      remaining == <<>> ->
        {:ok, Enum.reverse(terms), offset, :torn}

      true ->
        {:error, :corrupt}
    end
  end

  defp decode(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Creates an empty file readable only by its owner, unless the path exists, so the content is
  never readable by anyone else, not even between a write and a later chmod.
  """
  @spec create_private(Path.t()) :: :ok | {:error, term()}
  def create_private(path) do
    if File.exists?(path) do
      :ok
    else
      with :ok <- File.touch(path), do: File.chmod(path, 0o600)
    end
  end

  @doc "Cuts the file at `path` back to `size` bytes."
  @spec truncate(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def truncate(path, size) do
    with {:ok, device} <- :file.open(path, [:read, :write, :binary]) do
      result =
        with {:ok, _position} <- :file.position(device, size), do: :file.truncate(device)

      :file.close(device)
      result
    end
  end

  @doc "Replaces the content of `path` with `binary` and syncs it."
  @spec write_synced(Path.t(), binary()) :: :ok | {:error, term()}
  def write_synced(path, binary) do
    with {:ok, device} <- :file.open(path, [:write, :binary]) do
      result = with :ok <- :file.write(device, binary), do: :file.sync(device)
      :file.close(device)
      result
    end
  end

  @doc """
  Syncs the directory so a rename is durable. Not every platform lets Erlang open a directory, so
  a refusal is not a failure: the rename has already happened.
  """
  @spec sync_directory(Path.t()) :: :ok
  def sync_directory(directory) do
    with {:ok, device} <- :file.open(directory, [:read, :raw]) do
      :file.sync(device)
      :file.close(device)
    end

    :ok
  end

  @doc "Removes a file; one that is already missing is not an error."
  @spec remove_leftover(Path.t()) :: :ok | {:error, term()}
  def remove_leftover(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
