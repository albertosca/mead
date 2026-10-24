defmodule Mead.Session.Pool do
  @moduledoc """
  Dynamically starts and stops the per-conversation supervisors.

  The number of live sessions is bounded by `:maximum_sessions` (the option of `start_link/1`,
  then `config :mead, :maximum_sessions`, then #{1_000}); a session beyond it is refused with
  `{:error, :max_children}` instead of growing the node without limit.
  """

  use DynamicSupervisor

  alias Mead.Session

  @default_maximum_sessions 1_000

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options,
      name: Keyword.get(options, :name, __MODULE__)
    )
  end

  @impl true
  def init(options) do
    maximum_sessions =
      Keyword.get_lazy(options, :maximum_sessions, fn ->
        Application.get_env(:mead, :maximum_sessions, @default_maximum_sessions)
      end)

    DynamicSupervisor.init(strategy: :one_for_one, max_children: maximum_sessions)
  end

  @doc "Starts the supervisor pair for the conversation described by `options`."
  @spec start_session(keyword(), Supervisor.supervisor()) :: DynamicSupervisor.on_start_child()
  def start_session(options, pool \\ __MODULE__) do
    DynamicSupervisor.start_child(pool, {Session.Supervisor, options})
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
