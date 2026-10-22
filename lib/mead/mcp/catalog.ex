defmodule Mead.MCP.Catalog do
  @moduledoc """
  The tools the connected MCP servers offer, plus the normalized server configuration, in an ETS
  table any process can read.

  The process owns the table and is the only writer. A connection registers its tools after the
  handshake, and the catalog monitors that connection, so a connection that is killed without
  running `terminate/2` still loses its tools. A server re-registered by a newer connection keeps
  the new rows when the old connection's death is noticed afterwards.

  The configuration lives here so that `Mead.MCP.Hub` can ask the policy for a decision with one
  read and no call.
  """

  use GenServer

  @type tool :: %{name: String.t(), description: String.t() | nil, input_schema: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.fetch!(options, :name))
  end

  @spec register(atom(), atom(), pid(), [tool()]) :: :ok
  def register(catalog, server, owner, tools) do
    GenServer.call(catalog, {:register, server, owner, tools})
  end

  @spec unregister(atom(), atom()) :: :ok
  def unregister(catalog, server), do: GenServer.call(catalog, {:unregister, server})

  @spec snapshot(atom()) :: {:ok, [map()], [map()]} | :unavailable
  def snapshot(catalog) do
    entries =
      for {{:tools, server}, _owner, tools} <- :ets.match_object(catalog, {{:tools, :_}, :_, :_}),
          tool <- tools,
          do: Map.put(tool, :server, server)

    [{:servers, servers}] = :ets.lookup(catalog, :servers)

    {:ok, entries, servers}
  rescue
    ArgumentError -> :unavailable
  end

  @impl GenServer
  def init(options) do
    table =
      :ets.new(Keyword.fetch!(options, :name), [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    :ets.insert(table, {:servers, Keyword.get(options, :servers, [])})

    {:ok, %{table: table, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:register, server, owner, tools}, _from, state) do
    monitors = forget_monitor(state.monitors, server)
    :ets.insert(state.table, {{:tools, server}, owner, tools})

    {:reply, :ok, %{state | monitors: Map.put(monitors, server, Process.monitor(owner))}}
  end

  def handle_call({:unregister, server}, _from, state) do
    :ets.delete(state.table, {:tools, server})

    {:reply, :ok, %{state | monitors: forget_monitor(state.monitors, server)}}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.monitors, fn {_server, known} -> known == monitor end) do
      {server, _monitor} ->
        :ets.match_delete(state.table, {{:tools, server}, owner, :_})
        {:noreply, %{state | monitors: Map.delete(state.monitors, server)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp forget_monitor(monitors, server) do
    case Map.pop(monitors, server) do
      {nil, rest} ->
        rest

      {monitor, rest} ->
        Process.demonitor(monitor, [:flush])
        rest
    end
  end
end
