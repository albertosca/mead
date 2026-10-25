defmodule Mead.Ledger.JournalFile do
  @moduledoc """
  The file side of the ledger journal: `ledger.journal` in the storage directory, a sequence of
  `Mead.Session.Record` records, each one `Mead.Ledger.Journal` event.

  `read/1` has no side effect. `load/1` is what the ledger does at boot: it cuts a torn last
  record off the file, so that the next append does not land behind garbage, and it moves a file
  that is damaged anywhere else to `ledger.journal.corrupt` and starts empty, because the ledger
  is diagnostic and a damaged file must not stop the application. The name has no UUID shape, so
  `Mead.Session.Store.list/1` never mistakes the file for a conversation.
  """

  require Logger

  alias Mead.Ledger.Journal
  alias Mead.Session.Record

  @file_name "ledger.journal"

  @doc "The path of the journal in `directory`."
  @spec path(String.t()) :: Path.t()
  def path(directory), do: Path.join(directory, @file_name)

  @doc """
  Reads the journal into a model, without touching the file.

  Returns the model, the size of the valid prefix, and whether the file ended in a torn tail. An
  absent file is an empty model.
  """
  @spec read(String.t()) ::
          {:ok, Journal.t(), non_neg_integer(), :clean | :torn}
          | {:error, :corrupt | {:persistence, term()}}
  def read(directory) do
    case File.read(path(directory)) do
      {:ok, binary} ->
        with {:ok, events, valid_size, tail} <- Record.scan(binary),
             {:ok, model} <- Journal.replay(events) do
          {:ok, model, valid_size, tail}
        end

      {:error, :enoent} ->
        {:ok, Journal.new(), 0, :clean}

      {:error, reason} ->
        {:error, {:persistence, reason}}
    end
  end

  @doc "Reads the journal for the boot of the ledger, recovering from whatever it finds."
  @spec load(String.t()) :: Journal.t()
  def load(directory) do
    case read(directory) do
      {:ok, model, _valid_size, :clean} ->
        model

      {:ok, model, valid_size, :torn} ->
        Logger.warning("dropped an incomplete last record of the ledger journal")
        cut_tail(directory, valid_size)
        model

      {:error, :corrupt} ->
        set_aside(directory)
        Journal.new()

      {:error, {:persistence, reason}} ->
        Logger.warning("could not read the ledger journal: #{inspect(reason)}")
        Journal.new()
    end
  end

  defp cut_tail(directory, valid_size) do
    case Record.truncate(path(directory), valid_size) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not cut the ledger journal: #{inspect(reason)}")
    end
  end

  defp set_aside(directory) do
    journal = path(directory)

    case File.rename(journal, journal <> ".corrupt") do
      :ok ->
        Logger.warning("the ledger journal is damaged; moved to #{@file_name}.corrupt")

      {:error, reason} ->
        Logger.warning("the ledger journal is damaged and could not be moved: #{inspect(reason)}")
    end
  end

  @doc """
  Appends the events with one write and one sync, creating the directory and the file on first
  use. A failed write is rolled back to the size the file had before it.
  """
  @spec append(String.t(), [Journal.event()]) :: :ok | {:error, term()}
  def append(directory, events) do
    journal = path(directory)

    with :ok <- File.mkdir_p(directory),
         :ok <- Record.create_private(journal),
         {:ok, %File.Stat{size: size_before}} <- File.stat(journal),
         {:ok, device} <- File.open(journal, [:append, :binary]) do
      outcome =
        with :ok <- IO.binwrite(device, Enum.map(events, &Record.encode/1)),
             do: :file.sync(device)

      File.close(device)
      if outcome != :ok, do: Record.truncate(journal, size_before)
      outcome
    end
  end

  @doc "The size of the journal in bytes, or zero when it does not exist."
  @spec size(String.t()) :: non_neg_integer()
  def size(directory) do
    case File.stat(path(directory)) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
