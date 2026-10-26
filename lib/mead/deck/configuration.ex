defmodule Mead.Deck.Configuration do
  @moduledoc """
  Reads and validates `config :mead, :deck`.

  Pure, like `Mead.MCP.Server.Configuration`: it starts nothing and reads no application
  environment itself. Without a `:token` the deck endpoints are `:disabled`. Any other problem is
  an error whose message names the setting and never contains the token or any other value.

  The deck token is a separate secret from the MCP token. The struct keeps a SHA-256 digest of
  it, and its `Inspect` omits even the digest.

  ## Settings

    * `:token` - the bearer token the deck presents to `POST /deck/ticket` (a non-empty string;
      required to enable the deck).
    * `:ticket_ttl_ms` - how long a ticket can be redeemed; defaults to 10 000.
    * `:permission_timeout_ms` - how long a permission request or a choice waits for an answer
      before it expires; defaults to 120 000.
    * `:heartbeat_ms` - the heartbeat interval, at most 30 000 because the deck treats 40 s of
      silence as a dead connection; defaults to 15 000.
    * `:resume_deadline_ms` - how long a fresh socket may wait before sending `session.resume`;
      defaults to 10 000.
    * `:queue_limit` - how many prompts may wait behind a running turn; defaults to 10.
    * `:event_log_limit` - how many events a session's log keeps; once an idle channel holds more, the oldest are dropped (the latest permission policy is always kept); defaults to 10 000.
    * `:default_policy_level` - `:ask_always`, `:ask_for_risky` or `:allow_all`; defaults to
      `:ask_for_risky`.
  """

  @policy_levels [:ask_always, :ask_for_risky, :allow_all]
  @maximum_heartbeat_ms 30_000
  @positive_integer_defaults [
    ticket_ttl_ms: 10_000,
    permission_timeout_ms: 120_000,
    heartbeat_ms: 15_000,
    resume_deadline_ms: 10_000,
    queue_limit: 10,
    event_log_limit: 10_000
  ]
  @allowed_keys [:token, :default_policy_level | Keyword.keys(@positive_integer_defaults)]

  @derive {Inspect, except: [:token_digest]}
  @enforce_keys [
    :token_digest,
    :ticket_ttl_ms,
    :permission_timeout_ms,
    :heartbeat_ms,
    :resume_deadline_ms,
    :queue_limit,
    :event_log_limit,
    :default_policy_level
  ]
  defstruct @enforce_keys

  @type policy_level :: :ask_always | :ask_for_risky | :allow_all

  @type t :: %__MODULE__{
          token_digest: binary(),
          ticket_ttl_ms: pos_integer(),
          permission_timeout_ms: pos_integer(),
          heartbeat_ms: pos_integer(),
          resume_deadline_ms: pos_integer(),
          queue_limit: pos_integer(),
          event_log_limit: pos_integer(),
          default_policy_level: policy_level()
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
         {:ok, integers} <- fetch_positive_integers(settings),
         :ok <- check_heartbeat(integers.heartbeat_ms),
         {:ok, level} <- fetch_policy_level(settings) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(integers, %{
           token_digest: :crypto.hash(:sha256, token),
           default_policy_level: level
         })
       )}
    end
  end

  defp check_token(token) when is_binary(token) and token != "", do: :ok
  defp check_token(_token), do: {:error, "token must be a non-empty string"}

  defp fetch_positive_integers(settings) do
    Enum.reduce_while(@positive_integer_defaults, {:ok, %{}}, fn {name, default}, {:ok, found} ->
      case Keyword.get(settings, name, default) do
        value when is_integer(value) and value > 0 ->
          {:cont, {:ok, Map.put(found, name, value)}}

        _other ->
          {:halt, {:error, "#{name} must be a positive integer"}}
      end
    end)
  end

  defp check_heartbeat(heartbeat_ms) when heartbeat_ms <= @maximum_heartbeat_ms, do: :ok

  defp check_heartbeat(_heartbeat_ms),
    do: {:error, "heartbeat_ms must be at most #{@maximum_heartbeat_ms}"}

  defp fetch_policy_level(settings) do
    case Keyword.get(settings, :default_policy_level, :ask_for_risky) do
      level when level in @policy_levels -> {:ok, level}
      _other -> {:error, "default_policy_level must be one of #{inspect(@policy_levels)}"}
    end
  end
end
