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

  @doc false
  @spec load() :: :ok | {:error, term()}
  def load do
    if :os.type() == {:unix, :darwin} do
      result =
        :mead
        |> :code.priv_dir()
        |> Path.join("mead_native")
        |> String.to_charlist()
        |> :erlang.load_nif(0)

      if result == :ok, do: :persistent_term.put({__MODULE__, :loaded}, true)
      result
    else
      :ok
    end
  end

  @doc """
  Opens `path` (a file or a directory), flushes it to the drive with `F_FULLFSYNC`, and closes
  it.

  A file system with no `F_FULLFSYNC` gets `fsync` instead. Returns `{:error, posix}` when the
  path cannot be opened or flushed, and raises `ArgumentError` for a path that is not a binary.
  Only available on macOS.
  """
  @spec full_fsync(Path.t()) :: :ok | {:error, atom() | {:errno, integer()}}
  def full_fsync(_path), do: :erlang.nif_error(:not_loaded)

  @doc "Whether the native code is loaded: always on macOS, never elsewhere."
  @spec loaded?() :: boolean()
  def loaded?, do: :persistent_term.get({__MODULE__, :loaded}, false)
end
