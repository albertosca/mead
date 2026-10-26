defmodule Mead.MCP.Hub do
  @moduledoc """
  The client side of MCP for the runtime: a supervisor that keeps one `Mead.MCP.Connection` per
  configured server, and the two functions the router uses, `tools_for/2` and `call_tool/4`.

  The hub is not a process every call goes through. It starts a `Registry` and a
  `Mead.MCP.Catalog`, then the connections, under `:rest_for_one`; a call looks up the connection
  and talks to it directly, so sessions never queue behind each other. It comes after the
  session pool in `Mead.Supervisor`, so a crash here restarts the hub and the MCP server after it,
  and nothing before it.

  Configuration is read from `config :mead, :mcp, servers: [...]` (see
  `Mead.MCP.Configuration`) and validated when the hub starts: an invalid one stops the
  application at boot with a message instead of silently granting or denying the wrong tools.

  `tools_for/2` shows the model what the policy allows for the turn. `call_tool/4` authorizes the
  name again before any server is contacted, so a tool the model was not shown can never run.
  Both answer safely when the hub is not running: no tools, and `{:error, :hub_unavailable}`.

  The `:transports`, `:reconnect_delays`, and `:handshake_timeout` options exist for tests.
  """

  use Supervisor

  alias Mead.MCP.{Catalog, Configuration, Connection, Policy}

  @tool_timeout 15_000

  @default_transports %{
    stdio: {Mead.MCP.Transport.Stdio, []},
    http: {Mead.MCP.Transport.Http, []}
  }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl Supervisor
  def init(options) do
    hub = Keyword.get(options, :name, __MODULE__)
    servers = options |> Keyword.get_lazy(:servers, &configured_servers/0) |> validate!()

    await_released([registry_name(hub), catalog_name(hub)])

    children =
      [
        {Registry, keys: :unique, name: registry_name(hub)},
        {Catalog, name: catalog_name(hub), servers: servers}
      ] ++ Enum.map(servers, &connection_child(&1, hub, options))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec tools_for(keyword(), atom()) :: [
          %{name: String.t(), description: String.t() | nil, input_schema: map()}
        ]
  def tools_for(options, hub \\ __MODULE__) do
    case Catalog.snapshot(catalog_name(hub)) do
      {:ok, entries, servers} ->
        entries
        |> Policy.visible_tools(servers, options)
        |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))

      :unavailable ->
        []
    end
  end

  @spec call_tool(term(), term(), keyword(), atom()) ::
          {:ok, %{content: String.t(), is_error: boolean()}} | {:error, term()}
  def call_tool(name, arguments, options, hub \\ __MODULE__) do
    with {:ok, entries, servers} <- snapshot(hub),
         {:ok, target} <- Policy.authorize(name, entries, servers, options),
         :ok <- check_arguments(arguments) do
      Connection.call_tool(
        registry_name(hub),
        target.server,
        target.tool,
        arguments,
        @tool_timeout
      )
    end
  end

  @doc """
  What `call_tool/4` would run for `name`, without running it: the server, the tool and its class.
  The router needs the class to ask permission before the call. Fails like `call_tool/4` does for a
  name that is unknown or not allowed in this turn.
  """
  @spec describe_tool(term(), keyword(), atom()) ::
          {:ok, %{server: atom(), tool: String.t(), class: Policy.class()}} | {:error, term()}
  def describe_tool(name, options, hub \\ __MODULE__) do
    with {:ok, entries, servers} <- snapshot(hub) do
      Policy.authorize(name, entries, servers, options)
    end
  end

  defp snapshot(hub) do
    case Catalog.snapshot(catalog_name(hub)) do
      {:ok, entries, servers} -> {:ok, entries, servers}
      :unavailable -> {:error, :hub_unavailable}
    end
  end

  defp check_arguments(arguments) when is_map(arguments), do: :ok
  defp check_arguments(_arguments), do: {:error, :invalid_arguments}

  defp configured_servers do
    :mead |> Application.get_env(:mcp, []) |> Keyword.get(:servers, [])
  end

  defp validate!(servers) do
    case Configuration.validate(servers) do
      {:ok, validated} ->
        validated

      {:error, reason} ->
        raise ArgumentError, "invalid :mead, :mcp configuration: #{inspect(reason)}"
    end
  end

  defp connection_child(server, hub, options) do
    {kind, transport_options} = server.transport
    {module, extra_options} = options |> transports() |> Map.fetch!(kind)

    connection_options =
      [
        server: server.name,
        registry: registry_name(hub),
        catalog: catalog_name(hub),
        transport: {module, Keyword.merge(transport_options, extra_options)}
      ] ++ Keyword.take(options, [:reconnect_delays, :handshake_timeout])

    Supervisor.child_spec({Connection, connection_options}, id: {:connection, server.name})
  end

  # A hub that was killed brutally leaves its children to die from the exit signal, which can still
  # be in flight when the root supervisor starts the replacement. Without this wait the new hub
  # collides with the old registry's name, fails to start, and the root gives up after three tries.
  # The catalog and the registry also own named ETS tables, so a name counts as taken until both the
  # process and its table are gone.
  defp await_released(names, attempts \\ 100) do
    if Enum.any?(names, &taken?/1) and attempts > 0 do
      Process.sleep(10)
      await_released(names, attempts - 1)
    else
      :ok
    end
  end

  defp taken?(name), do: Process.whereis(name) != nil or :ets.whereis(name) != :undefined

  defp transports(options), do: Keyword.get(options, :transports, @default_transports)

  defp registry_name(hub), do: :"#{hub}.Registry"
  defp catalog_name(hub), do: :"#{hub}.Catalog"
end
