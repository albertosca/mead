defmodule Mead.Deck.Plug do
  @moduledoc """
  The HTTP side of the deck: the routes under `/deck`.

    * `POST /deck/ticket` - with the deck bearer token, creates a session (no body) or attaches to
      one (`{"session_id": "<uuid>"}`: running, or stopped with a stored history that is resumed)
      and answers `{"ticket", "session_id", "expires_in_ms"}`. The ticket is single use and short
      lived, so the token never travels in a URL.
    * `GET /deck/socket?ticket=...` - redeems the ticket and upgrades to a WebSocket served by
      `Mead.Deck.Socket`.
    * `GET /deck/events?ticket=...` - redeems the ticket and streams the same events as
      Server-Sent Events (`Mead.Deck.EventStream`), for a network where a WebSocket cannot pass.
    * `POST /deck/messages` - a client message for such a stream, authorised by the
      `connection_token` the stream announces first.

  Each check runs only if the previous ones passed: the route (404, or 405 with `allow`), the
  bearer token on the ticket route (401, checked in constant time before the body is read), the
  `Origin` header (403, the same rule and setting as MCP), then the request itself. Refusals are
  `{"error": "<reason>"}` and never repeat a header, a ticket or a body. No cookies and no CORS
  headers are set.

  ## Options

    * `:configuration` - the `Mead.Deck.Configuration` (required).
    * `:allowed_origins` - exact `Origin` values accepted besides loopback; defaults to `[]`.
    * `:session_options` - options for the session a ticket creates or resumes (`:handler`,
      `:turn_timeout`); defaults to the router as handler.
    * `:storage_directory` - where the event logs live; defaults to the session storage directory.
    * `:tickets` - the ticket table; defaults to `Mead.Deck.Tickets`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Mead.Deck.ChannelSupervisor
  alias Mead.Deck.Configuration
  alias Mead.Deck.EventStream
  alias Mead.Deck.Events
  alias Mead.Deck.Tickets
  alias Mead.Session
  alias Mead.Session.Store

  @maximum_body_bytes 4_096
  # Above the 64 KiB of `Events`, so a client frame that is merely too large is ignored by the
  # socket (the rule of the protocol); this limit is only the transport's bound on memory, and a
  # frame over it closes the connection with 1009.
  @transport_frame_limit_bytes 1_048_576

  @impl Plug
  def init(options) do
    %{
      configuration: Keyword.fetch!(options, :configuration),
      allowed_origins: Keyword.get(options, :allowed_origins, []),
      session_options: Keyword.get(options, :session_options, handler: Mead.Router),
      storage_directory: Keyword.get(options, :storage_directory, :default),
      tickets: Keyword.get(options, :tickets, Tickets)
    }
  end

  @impl Plug
  def call(%Plug.Conn{path_info: ["deck", "ticket"], method: "POST"} = conn, settings) do
    conn
    |> require_token(settings.configuration)
    |> require_origin(settings)
    |> issue_ticket(settings)
  end

  def call(%Plug.Conn{path_info: ["deck", "socket"], method: "GET"} = conn, settings) do
    conn
    |> require_origin(settings)
    |> upgrade(settings)
  end

  def call(%Plug.Conn{path_info: ["deck", "events"], method: "GET"} = conn, settings) do
    conn
    |> require_origin(settings)
    |> open_stream(settings)
  end

  def call(%Plug.Conn{path_info: ["deck", "messages"], method: "POST"} = conn, settings) do
    conn
    |> require_origin(settings)
    |> deliver_message()
  end

  def call(%Plug.Conn{path_info: ["deck", "ticket"]} = conn, _settings),
    do: reject(conn, 405, "method not allowed", [{"allow", "POST"}])

  def call(%Plug.Conn{path_info: ["deck", "socket"]} = conn, _settings),
    do: reject(conn, 405, "method not allowed", [{"allow", "GET"}])

  def call(%Plug.Conn{path_info: ["deck", "events"]} = conn, _settings),
    do: reject(conn, 405, "method not allowed", [{"allow", "GET"}])

  def call(%Plug.Conn{path_info: ["deck", "messages"]} = conn, _settings),
    do: reject(conn, 405, "method not allowed", [{"allow", "POST"}])

  def call(conn, _settings), do: reject(conn, 404, "not found")

  defp require_token(conn, configuration) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         true <- Configuration.token_matches?(configuration, token) do
      conn
    else
      _refused -> reject(conn, 401, "unauthorized", [{"www-authenticate", "Bearer"}])
    end
  end

  defp require_origin(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp require_origin(conn, %{allowed_origins: allowed_origins}) do
    case Mead.Origin.check(conn, allowed_origins) do
      :ok -> conn
      :forbidden -> reject(conn, 403, "forbidden origin")
    end
  end

  defp issue_ticket(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp issue_ticket(conn, settings) do
    with {:ok, requested, conn} <- read_requested_session(conn),
         {:ok, session_id} <- open_session(requested, settings.session_options) do
      ticket = Tickets.issue(settings.tickets, session_id, settings.configuration.ticket_ttl_ms)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_json(200, %{
        "ticket" => ticket,
        "session_id" => session_id,
        "expires_in_ms" => settings.configuration.ticket_ttl_ms
      })
    else
      {:error, status, message, conn} -> reject(conn, status, message)
      {:error, status, message} -> reject(conn, status, message)
    end
  end

  # No body means "start a new session"; a body must be a JSON object, and its `session_id`, when
  # there is one, a UUID of the shape the store accepts.
  defp read_requested_session(conn) do
    case read_body(conn, length: @maximum_body_bytes + 1) do
      {:ok, "", conn} ->
        {:ok, nil, conn}

      {:ok, body, conn} when byte_size(body) <= @maximum_body_bytes ->
        decode_requested_session(body, conn)

      {:ok, _body, conn} ->
        {:error, 413, "payload too large", conn}

      {:more, _partial, conn} ->
        {:error, 413, "payload too large", conn}

      {:error, _reason} ->
        {:error, 400, "the request body could not be read", conn}
    end
  end

  defp decode_requested_session(body, conn) do
    case JSON.decode(body) do
      {:ok, %{"session_id" => session_id}} ->
        if Store.valid_session_id?(session_id),
          do: {:ok, session_id, conn},
          else: {:error, 400, "session_id must be a session identifier", conn}

      {:ok, %{} = object} when map_size(object) == 0 ->
        {:ok, nil, conn}

      {:ok, %{}} ->
        {:error, 400, "the body may only carry session_id", conn}

      _not_an_object ->
        {:error, 400, "the body must be a JSON object", conn}
    end
  end

  defp open_session(nil, session_options), do: Mead.start_session(session_options) |> opened()

  defp open_session(session_id, session_options) do
    if Session.whereis(session_id, :supervisor) do
      {:ok, session_id}
    else
      case Mead.resume_session(session_id, session_options) do
        {:ok, ^session_id} -> {:ok, session_id}
        # Another request resumed it between the lookup and the call: it is running, which is all
        # a ticket needs.
        {:error, :already_running} -> {:ok, session_id}
        {:error, :not_found} -> {:error, 404, "session not found"}
        {:error, reason} -> opened({:error, reason})
      end
    end
  end

  defp opened({:ok, session_id}), do: {:ok, session_id}

  defp opened({:error, reason}) do
    Logger.error("deck could not open a session: #{inspect(reason)}")
    {:error, 500, "could not open the session"}
  end

  defp upgrade(%Plug.Conn{halted: true} = conn, _settings), do: conn

  # A request that is not a valid upgrade is refused before the ticket is redeemed, so a stray GET
  # cannot burn a ticket.
  defp upgrade(conn, settings) do
    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok ->
        redeem_and_upgrade(fetch_query_params(conn), settings)

      {:error, _reason} ->
        reject(conn, 426, "a WebSocket upgrade is required", [{"upgrade", "websocket"}])
    end
  end

  defp redeem_and_upgrade(conn, settings) do
    case redeem(conn, settings) do
      {:ok, session_id, channel} ->
        upgrade_to_socket(conn, session_id, channel, settings)

      {:refused, conn} ->
        conn
    end
  end

  # Redeems the ticket of the request and finds or starts the channel of its session; a refusal
  # comes back as the finished response.
  defp redeem(conn, settings) do
    with {:ok, session_id} <- Tickets.consume(settings.tickets, conn.query_params["ticket"]),
         {:ok, channel} <- ensure_channel(session_id, settings) do
      {:ok, session_id, channel}
    else
      :error -> {:refused, reject(conn, 401, "unauthorized", [{"www-authenticate", "Bearer"}])}
      {:error, :session_not_found} -> {:refused, reject(conn, 404, "session not found")}
      {:error, _reason} -> {:refused, reject(conn, 500, "could not open the channel")}
    end
  end

  # A bad resume position is refused before the ticket is redeemed, so it cannot burn a ticket.
  defp open_stream(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp open_stream(conn, settings) do
    conn = fetch_query_params(conn)

    case Events.parse_resume_position(conn.query_params, get_req_header(conn, "last-event-id")) do
      {:ok, position} ->
        case redeem(conn, settings) do
          {:ok, session_id, channel} ->
            stream =
              Map.merge(position, %{
                session_id: session_id,
                channel: channel,
                configuration: settings.configuration
              })

            EventStream.stream(conn, stream)

          {:refused, conn} ->
            conn
        end

      :error ->
        reject(conn, 400, "invalid resume position")
    end
  end

  defp deliver_message(%Plug.Conn{halted: true} = conn), do: conn

  defp deliver_message(conn) do
    case EventStream.message(conn) do
      {:ok, conn} -> conn
      :unauthorized -> reject(conn, 401, "unauthorized", [{"www-authenticate", "Bearer"}])
    end
  end

  defp upgrade_to_socket(conn, session_id, channel, settings) do
    conn
    |> WebSockAdapter.upgrade(
      Mead.Deck.Socket,
      %{channel: channel, session_id: session_id, configuration: settings.configuration},
      max_frame_size: @transport_frame_limit_bytes,
      # A deck that waits for a long turn sends nothing for minutes; the heartbeat from the
      # server, not an idle timer on the client, is what shows a connection is alive.
      timeout: :infinity,
      compress: false
    )
    |> halt()
  end

  defp ensure_channel(session_id, settings) do
    options = [configuration: settings.configuration]

    options =
      case settings.storage_directory do
        :default -> options
        directory -> Keyword.put(options, :storage_directory, directory)
      end

    ChannelSupervisor.ensure(session_id, options)
  end

  defp reject(conn, status, message, headers \\ []) do
    conn
    |> merge_resp_headers(headers)
    |> send_json(status, %{"error" => message})
    |> halt()
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
