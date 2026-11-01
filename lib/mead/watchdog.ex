defmodule Mead.Watchdog do
  @moduledoc """
  The application's top process: it starts the root supervisor and starts it again whenever it
  stops on its own, so a burst of failures past the root's restart budget no longer stops mead.

  A supervisor that runs out of restarts exits with `:shutdown`, the same reason an orderly stop
  uses, so the watchdog restarts its child whatever the reason; only its own parent stopping it, or
  `stand_down/1`, ends that. The wait before each restart starts at `initial_delay` (100 ms by
  default) and doubles after every exit or failed start that follows quickly, up to
  `maximum_delay` (5 seconds); a child that stayed up for `stable_after` (30 seconds) is started
  again after the initial wait. A start that fails is logged and tried again after the next wait,
  forever: what keeps a broken tree from spinning is the wait, not a count. Only the very first
  start is not retried, so a node that cannot boot says so at once.

  When the root comes back, `Mead.Session.Keeper` resumes the sessions whose turns the stop cut
  short, as it does at boot.
  """

  use GenServer

  require Logger

  @initial_delay 100
  @maximum_delay 5_000
  @stable_after 30_000

  @type option ::
          {:start, {module(), atom(), [term()]}}
          | {:name, GenServer.name()}
          | {:initial_delay, pos_integer()}
          | {:maximum_delay, pos_integer()}
          | {:stable_after, non_neg_integer()}

  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, shutdown: :infinity}
  end

  @doc """
  Starts the watchdog and, through `start`, its child. Returns the error of that first start when
  it fails.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @doc "The running child, or `nil` while it is down."
  @spec child(GenServer.server()) :: pid() | nil
  def child(watchdog), do: GenServer.call(watchdog, :child)

  @doc """
  Stops restarting: a pending restart is cancelled and a child that exits from now on stays down.
  The application calls it when it starts to stop, so the tree it is taking down is not brought
  back.
  """
  @spec stand_down(GenServer.server()) :: :ok
  def stand_down(watchdog), do: GenServer.call(watchdog, :stand_down)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      start: Keyword.fetch!(options, :start),
      initial_delay: Keyword.get(options, :initial_delay, @initial_delay),
      maximum_delay: Keyword.get(options, :maximum_delay, @maximum_delay),
      stable_after: Keyword.get(options, :stable_after, @stable_after),
      child: nil,
      started_at: nil,
      delay: nil,
      timer: nil,
      standing_down: false
    }

    case start_child(state.start) do
      {:ok, pid} -> {:ok, %{state | child: pid, started_at: now(), delay: state.initial_delay}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:child, _from, state), do: {:reply, state.child, state}

  def handle_call(:stand_down, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, %{state | standing_down: true, timer: nil}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{child: pid, standing_down: true} = state),
    do: {:noreply, %{state | child: nil}}

  def handle_info({:EXIT, pid, reason}, %{child: pid} = state) do
    delay =
      if now() - state.started_at >= state.stable_after,
        do: state.initial_delay,
        else: state.delay

    Logger.error(
      "root supervisor exited with #{inspect(reason)}; starting it again in #{delay} ms"
    )

    {:noreply, schedule(%{state | child: nil, started_at: nil}, delay)}
  end

  # A start that failed leaves the exit of its linked process behind.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:restart, %{standing_down: true} = state), do: {:noreply, state}

  def handle_info(:restart, state) do
    state = %{state | timer: nil}

    case start_child(state.start) do
      {:ok, pid} ->
        Logger.notice("root supervisor started again")
        {:noreply, %{state | child: pid, started_at: now()}}

      {:error, reason} ->
        Logger.error(
          "root supervisor failed to start with #{inspect(reason)}; trying again in #{state.delay} ms"
        )

        {:noreply, schedule(state, state.delay)}
    end
  end

  # The parent stopping the watchdog: take the tree down in order and wait for it, as a
  # supervisor would.
  @impl true
  def terminate(_reason, %{child: pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp schedule(state, delay) do
    timer = Process.send_after(self(), :restart, delay)
    %{state | timer: timer, delay: min(delay * 2, state.maximum_delay)}
  end

  defp start_child({module, function, arguments}) do
    case apply(module, function, arguments) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_start, other}}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
