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
      # Right after the pool: a pool restart restarts it, and it resumes the marked sessions. A
      # hub crash, which restarts every child after the hub, never reaches it.
      Mead.Session.Keeper,
      # After the pool; a hub crash must not restart the deck channels.
      Mead.Deck.ChannelSupervisor,
      # After the pool, so that a crash of the hub never restarts the pool.
      Mead.MCP.Hub,
      # Right after the hub, so it stops before the hub when an earlier child crashes, and
      # suspends the running turns while the hub they may be calling is still up.
      Mead.Session.ShutdownGuard,
      # Before the listener, which serves the deck's ticket endpoint from this table.
      Mead.Deck.Tickets,
      # Last, so that a crash of the listener restarts only the listener.
      Mead.MCP.Server
    ]

    # The watchdog sits above the root, so a root that runs out of restarts is started again
    # instead of stopping the application; the keeper then continues the turns it cut.
    Mead.Watchdog.start_link(
      name: Mead.Watchdog,
      start: {Supervisor, :start_link, [children, supervisor_options()]}
    )
  end

  # Runs before any child stops, while the hub and the channels are still up, so a turn cut by the
  # shutdown is suspended (and continues at the next boot) instead of recording a failure. The
  # listener goes first, so no client starts a turn after the suspension that the shutdown would
  # then cut. The watchdog stands down first, so it does not bring back the tree the stop takes
  # down, and a root that is down at that moment (the watchdog waiting to restart it) has nothing
  # to suspend: its turns were suspended when it stopped and stay marked.
  @impl true
  def prep_stop(state) do
    Mead.Watchdog.stand_down(Mead.Watchdog)

    if Process.whereis(Mead.Supervisor) do
      try do
        Supervisor.terminate_child(Mead.Supervisor, Mead.MCP.Server)
        Mead.Session.Keeper.suspend_all()
      catch
        # The root stopped between the check and the call.
        :exit, _reason -> :ok
      end
    end

    state
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
