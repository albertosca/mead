defmodule Mead.Session.Keeper do
  @moduledoc """
  Brings back the sessions whose turns were cut short, and suspends running turns when the node
  stops in order.

  On every start it reads the markers under `Mead.Session.Pending` and resumes each marked session
  that is not running, with the handler and turn timeout the marker recorded; the session's server
  then continues its turn (see `Mead.Session.Server`). It is the root child right after
  `Mead.Session.Pool`, so a restart of the pool, or of anything before it, restarts the keeper,
  which recovers the turns that restart cut short: it first waits, at most 5 seconds, for the
  processes of the old pool's sessions to exit. Recovery runs after `init/1` returns and never
  blocks the rest of the boot. Without a storage directory it does nothing.

  For each marker:

    * a session that is running is left alone;
    * a resumed session needs nothing more: its server removes the marker when it has nothing to
      continue, and when the continued turn ends;
    * a session with no file, or a damaged one, loses its marker, with a warning;
    * any other error, a handler that no longer validates included, is logged and the marker is
      kept, so a later start can try again. One bad session never stops the others.

  `suspend_all/0`, called by the application's `prep_stop/1` callback before any child stops, suspends every
  running session server, so no turn records a failure the shutdown itself caused; each continues
  at the next boot.
  """

  use GenServer

  require Logger

  alias Mead.Session.Pending
  alias Mead.Session.Pool
  alias Mead.Session.Server
  alias Mead.Session.Store

  @previous_wait 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Resumes every marked session of `directory` that is not running. Always `:ok`."
  @spec recover(String.t() | nil) :: :ok
  def recover(directory) do
    directory
    |> Pending.list()
    |> Enum.each(fn {session_id, settings} ->
      recover_session(directory, session_id, settings)
    end)
  end

  @doc """
  Suspends the running turn of every session on this node. Always `:ok`.

  The servers are found through the pool's supervision tree, not the registry, so this works when the registry is the child whose crash is taking the rest down.
  """
  @spec suspend_all() :: :ok
  def suspend_all do
    for {_id, session, _type, _modules} <- children(Pool),
        is_pid(session),
        {Server, server, _type, _modules} <- children(session),
        is_pid(server) do
      Server.suspend(server)
    end

    :ok
  end

  # A supervisor that is gone or stopping has no children to suspend.
  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
  end

  @impl true
  def init(nil), do: {:ok, nil, {:continue, :recover}}

  @impl true
  def handle_continue(:recover, state) do
    case Store.directory() do
      nil ->
        :ok

      directory ->
        await_previous_sessions()
        recover(directory)
    end

    {:noreply, state}
  end

  # After a pool restart the processes of the old pool's sessions can still be registered for a
  # moment (dying, or dead with the registry not yet told), and resuming such a session would
  # answer :already_running or fail to register. So the keeper first waits, at most
  # @previous_wait milliseconds, for every registered session process that does not belong to the
  # current pool to exit. At boot there is none.
  defp await_previous_sessions do
    current =
      for {_id, supervisor, _type, _modules} <- DynamicSupervisor.which_children(Pool),
          is_pid(supervisor),
          into: MapSet.new(),
          do: supervisor

    current_sessions =
      for {session_id, supervisor} <- registered(:supervisor),
          MapSet.member?(current, supervisor),
          into: MapSet.new(),
          do: session_id

    deadline = System.monotonic_time(:millisecond) + @previous_wait

    for role <- [:supervisor, :server, :history],
        {session_id, pid} <- registered(role),
        not MapSet.member?(current_sessions, session_id) do
      await_exit(pid, deadline)
    end

    :ok
  end

  defp registered(role) do
    Registry.select(Mead.Registry, [{{{role, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  # The registry drops a name only after the process is gone, so the name is waited for too.
  defp await_exit(pid, deadline) do
    monitor = Process.monitor(pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      remaining -> Process.demonitor(monitor, [:flush])
    end

    await_unregistered(pid, deadline)
  end

  defp await_unregistered(pid, deadline) do
    still_registered =
      Registry.select(Mead.Registry, [{{:_, :"$1", :_}, [{:==, :"$1", pid}], [true]}]) != []

    if still_registered and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_unregistered(pid, deadline)
    end
  end

  defp recover_session(directory, session_id, settings) do
    options = [handler: settings.handler, turn_timeout: settings.turn_timeout]

    case resume(session_id, options) do
      {:ok, _session_id} ->
        Logger.info("resumed session #{session_id} to continue its turn")

      {:error, :already_running} ->
        :ok

      {:error, reason} when reason in [:not_found, :corrupt_history] ->
        Logger.warning("dropped the pending marker of session #{session_id}: #{inspect(reason)}")
        clear(directory, session_id)

      {:error, reason} ->
        Logger.error("could not resume session #{session_id}: #{inspect(reason)}")
    end
  end

  defp resume(session_id, options) do
    Mead.resume_session(session_id, options)
  rescue
    error in ArgumentError -> {:error, {:invalid_options, Exception.message(error)}}
  end

  defp clear(directory, session_id) do
    case Pending.clear(directory, session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not remove the pending marker of session #{session_id}: #{inspect(reason)}"
        )
    end
  end
end
