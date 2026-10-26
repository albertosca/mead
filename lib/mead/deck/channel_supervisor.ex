defmodule Mead.Deck.ChannelSupervisor do
  @moduledoc """
  Starts and stops the `Mead.Deck.Channel` of each session. A channel is `:temporary`: when it
  stops, a reconnecting deck asks for a new one through `ensure/2`, and the event log it keeps on
  disk carries the sequence over.
  """

  use DynamicSupervisor

  alias Mead.Deck.Channel

  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options,
      name: Keyword.get(options, :name, __MODULE__)
    )
  end

  @impl DynamicSupervisor
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Returns the channel of `session_id`, starting it when there is none.

  ## Options

    * `:configuration` - the `Mead.Deck.Configuration` to use (required).
    * `:storage_directory` - where the event log lives; defaults to the session storage
      directory, and `nil` keeps the log in memory.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(session_id, options \\ []) do
    case Registry.lookup(Mead.Registry, {:deck, session_id}) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_channel(session_id, options)

      [] ->
        start_channel(session_id, options)
    end
  end

  defp start_channel(session_id, options) do
    supervisor = Keyword.get(options, :supervisor, __MODULE__)

    child = %{
      id: {:deck, session_id},
      start: {Channel, :start_link, [Keyword.put(options, :session_id, session_id)]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the channel of a session and waits until it is gone; no channel is not an error."
  @spec stop(String.t(), Supervisor.supervisor()) :: :ok
  def stop(session_id, supervisor \\ __MODULE__) do
    case Registry.lookup(Mead.Registry, {:deck, session_id}) do
      [{pid, _value}] ->
        _ = DynamicSupervisor.terminate_child(supervisor, pid)
        :ok

      [] ->
        :ok
    end
  end
end
