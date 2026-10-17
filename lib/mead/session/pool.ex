defmodule Mead.Session.Pool do
  @moduledoc """
  Dynamically starts and stops the per-conversation supervisors.
  """

  use DynamicSupervisor

  alias Mead.Session

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arguments) do
    DynamicSupervisor.start_link(__MODULE__, arguments, name: __MODULE__)
  end

  @impl true
  def init(_arguments) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts the supervisor pair for the conversation described by `options`."
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(options) do
    DynamicSupervisor.start_child(__MODULE__, {Session.Supervisor, options})
  end

  @doc "Stops a conversation's supervisor pair, discarding its history."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case Session.whereis(session_id, :supervisor) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
