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
      # After the pool, so that a crash of the hub never restarts the pool.
      Mead.MCP.Hub,
      # Before the listener, which serves the deck's ticket endpoint from this table.
      Mead.Deck.Tickets,
      # Last, so that a crash of the listener restarts only the listener.
      Mead.MCP.Server
    ]

    Supervisor.start_link(children, supervisor_options())
  end

  # Killing a root child restarts everything after it, which counts as one restart. OTP's default
  # of 3 restarts in 5 seconds leaves no room for a test, or a short burst of real failures, to
  # kill a child without taking the whole application down; a crash loop still escalates.
  @doc false
  @spec supervisor_options() :: keyword()
  def supervisor_options do
    [strategy: :rest_for_one, name: Mead.Supervisor, max_restarts: 10, max_seconds: 5]
  end
end
