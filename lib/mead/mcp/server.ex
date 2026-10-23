defmodule Mead.MCP.Server do
  @moduledoc """
  The server side of MCP: an HTTP listener that lets a client with the configured token drive
  sessions as tools (see `Mead.MCP.Server.Tools`). The last child of the root supervisor.

  Configured by `config :mead, :mcp_server` (see `Mead.MCP.Server.Configuration`). Without a
  `:token` it starts nothing and logs one info line, so a runtime that was never set up for it
  opens no port. An invalid setting stops the application at boot with a message that names the
  setting and never contains the token.

  The listener is a `Bandit` instance running `Mead.MCP.Server.Plug`. It is supervised
  `:one_for_one`, so a listener that dies is started again without touching the hub or the
  sessions. A port that is already taken stops the start, loudly, as any other boot error.
  """

  use Supervisor

  require Logger

  alias Mead.MCP.Server.Configuration

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl Supervisor
  def init(options) do
    settings =
      Keyword.get_lazy(options, :settings, fn -> Application.get_env(:mead, :mcp_server, []) end)

    case Configuration.load(settings) do
      :disabled ->
        Logger.info("MCP server is disabled: no :token is configured under :mcp_server")
        Supervisor.init([], strategy: :one_for_one)

      {:ok, configuration} ->
        Supervisor.init([listener(configuration)], strategy: :one_for_one)

      {:error, message} ->
        raise ArgumentError, "invalid :mead, :mcp_server configuration: #{message}"
    end
  end

  @doc """
  The port the listener is bound to, which is what a test that asked for port 0 needs to know.
  `:error` when the server has no listener or is not running.
  """
  @spec port(Supervisor.supervisor()) :: {:ok, :inet.port_number()} | :error
  def port(server \\ __MODULE__) do
    with [{_id, listener, :supervisor, _modules}] when is_pid(listener) <-
           Supervisor.which_children(server),
         {:ok, {_address, port}} <- ThousandIsland.listener_info(listener) do
      {:ok, port}
    else
      _no_listener -> :error
    end
  catch
    :exit, _reason -> :error
  end

  defp listener(configuration) do
    {Bandit,
     plug: {Mead.MCP.Server.Plug, [configuration: configuration]},
     scheme: :http,
     ip: configuration.address,
     port: configuration.port,
     startup_log: false}
  end
end
