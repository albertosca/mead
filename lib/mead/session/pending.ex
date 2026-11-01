defmodule Mead.Session.Pending do
  @moduledoc """
  Small marker files, one per session with a keyed turn in progress, so that recovery finds the
  turns to continue without reading every conversation.

  A marker lives at `<storage>/pending/<session_id>` and holds the handler and the turn timeout
  the session was started with, which the conversation file does not keep. It is written synced
  (file and directory) before the turn is recorded, and removed when the turn ends. Without a
  storage directory nothing is written and nothing is listed.
  """

  alias Mead.Session.Record
  alias Mead.Session.Store

  @type settings :: %{handler: module(), turn_timeout: pos_integer()}

  @doc "Writes the marker of a session, replacing an earlier one."
  @spec mark(String.t() | nil, String.t(), settings()) :: :ok | {:error, term()}
  def mark(nil, _session_id, _settings), do: :ok

  def mark(directory, session_id, settings) do
    if Store.valid_session_id?(session_id) do
      folder = folder(directory)
      path = Path.join(folder, session_id)
      temporary = path <> ".tmp"

      result =
        with :ok <- File.mkdir_p(folder),
             :ok <- Record.remove_leftover(temporary),
             :ok <- Record.create_private(temporary),
             :ok <- Record.write_synced(temporary, :erlang.term_to_binary(settings)),
             :ok <- File.rename(temporary, path) do
          Record.sync_directory(folder)
        end

      File.rm(temporary)
      result
    else
      {:error, :invalid_session_id}
    end
  end

  @doc "Removes the marker of a session; a missing one is not an error."
  @spec clear(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def clear(nil, _session_id), do: :ok

  def clear(directory, session_id) do
    folder = folder(directory)

    # The directory is synced too, so a power cut does not bring back a marker already cleared.
    with true <- Store.valid_session_id?(session_id),
         :ok <- Record.remove_leftover(Path.join(folder, session_id)) do
      Record.sync_directory(folder)
    else
      false -> :ok
      error -> error
    end
  end

  @doc "Lists the marked sessions with their settings, ignoring anything that is not a marker."
  @spec list(String.t() | nil) :: [{String.t(), settings()}]
  def list(nil), do: []

  def list(directory) do
    folder = folder(directory)

    case File.ls(folder) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&entry(folder, &1))
      {:error, _reason} -> []
    end
  end

  defp entry(folder, name) do
    with true <- Store.valid_session_id?(name),
         {:ok, binary} <- File.read(Path.join(folder, name)),
         %{handler: handler, turn_timeout: turn_timeout} = settings
         when is_atom(handler) and is_integer(turn_timeout) <- decode(binary) do
      [{name, settings}]
    else
      _not_a_marker -> []
    end
  end

  # Markers are written by this node into its own private directory, like the conversation files.
  defp decode(binary) do
    :erlang.binary_to_term(binary)
  rescue
    ArgumentError -> nil
  end

  defp folder(directory), do: Path.join(directory, "pending")
end
