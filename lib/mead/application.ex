defmodule Mead.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _arguments) do
    # The ledger comes first so a crash of a later child does not wipe its numbers, while a crash
    # of the ledger itself restarts everything after it.
    children = [
      Mead.Ledger,
      {Registry, keys: :unique, name: Mead.Registry},
      {Task.Supervisor, name: Mead.TurnSupervisor},
      Mead.Session.Pool,
      # Last, so that a crash of the hub restarts only the hub and never the session pool.
      Mead.MCP.Hub
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Mead.Supervisor)
  end
end
