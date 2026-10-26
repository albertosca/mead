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

  @acceptors 10

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl Supervisor
  def init(options) do
    mcp_settings =
      Keyword.get_lazy(options, :settings, fn -> Application.get_env(:mead, :mcp_server, []) end)

    deck_settings =
      Keyword.get_lazy(options, :deck_settings, fn -> Application.get_env(:mead, :deck, []) end)

    mcp = load_mcp(mcp_settings)
    deck = load_deck(deck_settings)

    case {mcp, deck} do
      {:disabled, :disabled} ->
        Logger.info("MCP server is disabled: no :token is configured under :mcp_server")
        Supervisor.init([], strategy: :one_for_one)

      _enabled ->
        {:ok, listener} = Configuration.listener(mcp_settings)
        Supervisor.init([listener_child(listener, mcp, deck)], strategy: :one_for_one)
    end
  end

  defp load_mcp(settings) do
    case Configuration.load(settings) do
      {:error, message} ->
        raise ArgumentError, "invalid :mead, :mcp_server configuration: #{message}"

      loaded ->
        loaded
    end
  end

  defp load_deck(settings) do
    case Mead.Deck.Configuration.load(settings) do
      {:error, message} -> raise ArgumentError, "invalid :mead, :deck configuration: #{message}"
      loaded -> loaded
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

  defp listener_child(listener, mcp, _deck) do
    mcp_plug =
      case mcp do
        {:ok, configuration} -> {Mead.MCP.Server.Plug, [configuration: configuration]}
        :disabled -> nil
      end

    {Bandit,
     plug: {Mead.Gateway, mcp: mcp_plug, deck: nil},
     scheme: :http,
     ip: listener.address,
     port: listener.port,
     thousand_island_options: connection_limits(listener.maximum_connections),
     startup_log: false}
  end

  # Thousand Island limits connections per acceptor, so the total is acceptors times the limit of
  # each; a limit that is not a multiple of the acceptors is rounded up to one. A connection over
  # the limit is closed after a short wait for room, not queued without bound.
  defp connection_limits(maximum_connections) do
    acceptors = min(maximum_connections, @acceptors)

    [
      num_acceptors: acceptors,
      num_connections: div(maximum_connections + acceptors - 1, acceptors),
      max_connections_retry_wait: 200,
      max_connections_retry_count: 5
    ]
  end
end
