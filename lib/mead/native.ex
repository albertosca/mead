defmodule Mead.Native do
  @moduledoc """
  The native code mead needs where Erlang's file API falls short, built from `c_src/` on macOS
  only.

  On macOS, `:file.sync/1` calls `fcntl(F_BARRIERFSYNC)`, which keeps writes in order but does
  not ask the drive to flush its cache, so a power cut can lose writes it acknowledged.
  `full_fsync/1` calls `fcntl(F_FULLFSYNC)`, which does. On Linux, `:file.sync/1` is `fsync`,
  which already flushes, so nothing is built or loaded there, and nothing needs a C compiler.
  `Mead.Session.Record.sync/2` chooses between them.
  """

  @on_load :load

  # Always :ok, so a library that fails to load leaves the module available with its status, and
  # Mead.Application refuses to start with the reason instead of every sync raising later.
  @doc false
  @spec load() :: :ok
  def load do
    status =
      if :os.type() == {:unix, :darwin} do
        :mead |> :code.priv_dir() |> Path.join("mead_native") |> load_from() |> loaded_status()
      else
        :not_needed
      end

    :persistent_term.put({__MODULE__, :status}, status)
    :ok
  end

  @doc false
  @spec load_from(Path.t()) :: :ok | {:error, term()}
  def load_from(path), do: path |> String.to_charlist() |> :erlang.load_nif(0)

  defp loaded_status(:ok), do: :loaded
  defp loaded_status({:error, reason}), do: {:error, reason}

  @doc """
  Opens `path` (a file or a directory), flushes it to the drive with `F_FULLFSYNC`, and closes
  it.

  A file system with no `F_FULLFSYNC` gets `fsync` instead. Returns `{:error, posix}` when the
  path cannot be opened or flushed, and raises `ArgumentError` for a path that is not a binary.
  Only available on macOS.
  """
  @spec full_fsync(Path.t()) :: :ok | {:error, atom() | {:errno, integer()}}
  def full_fsync(_path), do: :erlang.nif_error(:not_loaded)

  @doc """
  `:loaded` on macOS, `:not_needed` elsewhere, or `{:error, reason}` when macOS could not load the
  library (the application then refuses to start).
  """
  @spec status() :: :loaded | :not_needed | {:error, term()}
  def status, do: :persistent_term.get({__MODULE__, :status}, :not_needed)

  @doc "Whether the native code is loaded: on macOS once it loaded, never elsewhere."
  @spec loaded?() :: boolean()
  def loaded?, do: status() == :loaded
end
