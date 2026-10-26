defmodule Mead.MCP.Server.Configuration do
  @moduledoc """
  Reads and validates `config :mead, :mcp_server`.

  Pure: it starts nothing and reads no application environment itself; `Mead.MCP.Server` hands
  it the settings. Without a `:token` the server is `:disabled`. Any other problem is an error
  whose message names the setting and never contains the token or any other value.

  The struct keeps a SHA-256 digest of the token, not the token, and its `Inspect` omits even
  the digest, so the listener options that carry the struct leak nothing into a crash report or
  `:sys.get_status/1`. Hashing both sides before comparing also gives `secure_compare/2` two
  binaries of equal length whatever the client sent.

  ## Settings

    * `:token` - the bearer token clients must present (a non-empty string; required to enable
      the server).
    * `:port` - `0..65535`; defaults to 4040. Tests use 0 and ask the listener for its port.
    * `:address` - an IPv4 tuple; defaults to loopback `{127, 0, 0, 1}`.
    * `:allow_effect` - whether `tools: "effect"` is honoured; defaults to `false`.
    * `:allowed_origins` - exact `Origin` values accepted besides loopback; defaults to `[]`.
    * `:maximum_connections` - how many connections the listener serves at once, rounded up to a
      multiple of 10 from 10 on; a connection over the limit is closed after about a second
      without room. A positive integer; defaults to 250.
    * `:certfile` and `:keyfile` - paths to a PEM certificate chain and its private key. Both
      together make the listener speak HTTPS (and WSS for the deck); either alone is an error;
      without them it speaks plain HTTP. The files are not read here, only the shape is checked,
      so a missing file stops the listener at boot with the TLS library's own message.
  """

  @allowed_keys [
    :token,
    :port,
    :address,
    :allow_effect,
    :allowed_origins,
    :maximum_connections,
    :certfile,
    :keyfile
  ]
  @default_port 4040
  @default_address {127, 0, 0, 1}
  @default_maximum_connections 250

  @derive {Inspect, except: [:token_digest]}
  @enforce_keys [
    :token_digest,
    :port,
    :address,
    :allow_effect,
    :allowed_origins,
    :maximum_connections
  ]
  defstruct [
    :token_digest,
    :port,
    :address,
    :allow_effect,
    :allowed_origins,
    :maximum_connections
  ]

  @type t :: %__MODULE__{
          token_digest: binary(),
          port: 0..65_535,
          address: :inet.ip4_address(),
          allow_effect: boolean(),
          allowed_origins: [String.t()],
          maximum_connections: pos_integer()
        }

  @spec load(term()) :: :disabled | {:ok, t()} | {:error, String.t()}
  def load(settings) do
    with :ok <- check_shape(settings),
         :ok <- check_keys(settings) do
      case Keyword.get(settings, :token) do
        nil -> :disabled
        token -> build(token, settings)
      end
    end
  end

  @doc """
  Reads only the listener settings (`:port`, `:address`, `:allowed_origins`,
  `:maximum_connections`), which are valid with or without a token, so the shared listener can
  start for the deck alone. The deck applies the same `Origin` rule as MCP.
  """
  @spec listener(term()) ::
          {:ok,
           %{
             port: 0..65_535,
             address: :inet.ip4_address(),
             allowed_origins: [String.t()],
             maximum_connections: pos_integer(),
             tls: nil | [certfile: Path.t(), keyfile: Path.t()]
           }}
          | {:error, String.t()}
  def listener(settings) do
    with :ok <- check_shape(settings),
         :ok <- check_keys(settings),
         {:ok, port} <- fetch_port(settings),
         {:ok, address} <- fetch_address(settings),
         {:ok, allowed_origins} <- fetch_allowed_origins(settings),
         {:ok, maximum_connections} <- fetch_maximum_connections(settings),
         {:ok, tls} <- fetch_tls(settings) do
      {:ok,
       %{
         port: port,
         address: address,
         allowed_origins: allowed_origins,
         maximum_connections: maximum_connections,
         tls: tls
       }}
    end
  end

  @doc "Whether `presented` is the configured token, compared in constant time."
  @spec token_matches?(t(), term()) :: boolean()
  def token_matches?(%__MODULE__{token_digest: digest}, presented) when is_binary(presented) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, presented), digest)
  end

  def token_matches?(%__MODULE__{}, _presented), do: false

  defp check_shape(settings) do
    if Keyword.keyword?(settings), do: :ok, else: {:error, "settings must be a keyword list"}
  end

  defp check_keys(settings) do
    case Keyword.keys(settings) -- @allowed_keys do
      [] -> :ok
      unknown -> {:error, "unknown setting(s): #{inspect(unknown)}"}
    end
  end

  defp build(token, settings) do
    with :ok <- check_token(token),
         {:ok, port} <- fetch_port(settings),
         {:ok, address} <- fetch_address(settings),
         {:ok, allow_effect} <- fetch_allow_effect(settings),
         {:ok, allowed_origins} <- fetch_allowed_origins(settings),
         {:ok, maximum_connections} <- fetch_maximum_connections(settings) do
      {:ok,
       %__MODULE__{
         token_digest: :crypto.hash(:sha256, token),
         port: port,
         address: address,
         allow_effect: allow_effect,
         allowed_origins: allowed_origins,
         maximum_connections: maximum_connections
       }}
    end
  end

  defp check_token(token) when is_binary(token) and token != "", do: :ok
  defp check_token(_token), do: {:error, "token must be a non-empty string"}

  defp fetch_port(settings) do
    case Keyword.get(settings, :port, @default_port) do
      port when is_integer(port) and port >= 0 and port <= 65_535 -> {:ok, port}
      _other -> {:error, "port must be an integer from 0 to 65535"}
    end
  end

  defp fetch_address(settings) do
    case Keyword.get(settings, :address, @default_address) do
      {first, second, third, fourth} = address
      when first in 0..255 and second in 0..255 and third in 0..255 and fourth in 0..255 ->
        {:ok, address}

      _other ->
        {:error, "address must be an IPv4 tuple such as {127, 0, 0, 1}"}
    end
  end

  defp fetch_allow_effect(settings) do
    case Keyword.get(settings, :allow_effect, false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "allow_effect must be true or false"}
    end
  end

  defp fetch_maximum_connections(settings) do
    case Keyword.get(settings, :maximum_connections, @default_maximum_connections) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "maximum_connections must be a positive integer"}
    end
  end

  defp fetch_tls(settings) do
    case {Keyword.get(settings, :certfile), Keyword.get(settings, :keyfile)} do
      {nil, nil} ->
        {:ok, nil}

      {certfile, keyfile} when is_binary(certfile) and is_binary(keyfile) ->
        if certfile != "" and keyfile != "",
          do: {:ok, [certfile: certfile, keyfile: keyfile]},
          else: {:error, "certfile and keyfile must be non-empty paths"}

      {certfile, keyfile} when is_nil(certfile) or is_nil(keyfile) ->
        {:error, "certfile and keyfile must be set together"}

      _other ->
        {:error, "certfile and keyfile must be non-empty paths"}
    end
  end

  defp fetch_allowed_origins(settings) do
    case Keyword.get(settings, :allowed_origins, []) do
      origins when is_list(origins) ->
        if Enum.all?(origins, &is_binary/1) do
          {:ok, origins}
        else
          {:error, "allowed_origins must be a list of strings"}
        end

      _other ->
        {:error, "allowed_origins must be a list of strings"}
    end
  end
end
