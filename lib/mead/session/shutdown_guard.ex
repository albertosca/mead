defmodule Mead.Session.ShutdownGuard do
  @moduledoc """
  Suspends the running turns when a crash of an earlier root child takes the tree down.

  The root supervisor is `rest_for_one`: a crash of the ledger, the registry or the turn supervisor
  stops every child after it, newest first, so the hub stops before the session pool and a turn in
  the middle of a tool call would record a failure the restart caused. This child sits right after
  the hub, so it stops before the hub does; when it stops while the hub is still up, it suspends
  every session (`Mead.Session.Keeper.suspend_all/0`), and the keeper continues their turns once the
  pool is back.

  A crash of a child between the pool and the hub (the keeper, the deck channel supervisor) also
  stops this child while the hub is up, so it suspends, but the pool is not restarted and the
  suspended servers stay. So when this child starts again it revives every suspended session
  (`Mead.Session.Keeper.revive_all/0`), and their turns continue; after a restart that did replace
  the pool, and at boot, there is none.

  A crash of the hub itself also stops this child, after the hub is gone. It then does nothing: the
  sessions keep running, and the hub comes back on its own. An orderly
  stop has already suspended everything in `prep_stop/1`, so a second pass finds nothing to do.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Mead.Session.Keeper.revive_all()
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    if hub_alive?(), do: Mead.Session.Keeper.suspend_all()
    :ok
  end

  defp hub_alive? do
    case Process.whereis(Mead.MCP.Hub) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
