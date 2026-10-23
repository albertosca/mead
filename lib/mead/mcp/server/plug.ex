defmodule Mead.MCP.Server.Plug do
  @moduledoc """
  The HTTP side of the MCP server: `POST /mcp`, one JSON-RPC message per request.

  Each check runs only if the previous ones passed, and the first failure answers and halts:

    1. the route: any path but `/mcp` is 404, any method but POST is 405 with `allow: POST`
       (the server has no event stream to offer);
    2. the bearer token (401, `www-authenticate: Bearer`), compared in constant time and checked
       before the body is read, so an unauthenticated client makes the server read nothing;
    3. the `Origin` header, when present: loopback or listed in `allowed_origins`, else 403.
       This is the protection against DNS rebinding that the MCP specification asks for;
    4. the content type: `application/json`, else 415;
    5. the body: at most 1 MiB, else 413;
    6. decoding: text that is not JSON is 400 with `-32700`; JSON that is not a request,
       notification, or response (a batch included) is 400 with `-32600`.

  Every refusal is a JSON-RPC error with `"id": null`. A message that decodes is handed to the
  dispatcher: a reply is 200 with one JSON object, no reply is 202 with an empty body. A bug in
  the dispatcher becomes a generic 500; only the exception module is logged, because a crash
  report of a request process can print the whole connection, `Authorization` header included.

  No cookies and no CORS headers are ever set.

  ## Options

    * `:configuration` - the `Mead.MCP.Server.Configuration` (required).
    * `:dispatcher` - a module with `dispatch/2`; defaults to `Mead.MCP.Server.Dispatcher`, and is
      only replaced by tests.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Mead.MCP.Protocol
  alias Mead.MCP.Server.Configuration
  alias Mead.MCP.Server.Dispatcher

  @maximum_body_bytes 1024 * 1024
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]
  @refused -32_000
  @parse_error -32_700
  @invalid_request -32_600
  @internal_error -32_603

  @impl Plug
  def init(options) do
    %{
      configuration: Keyword.fetch!(options, :configuration),
      dispatcher: Keyword.get(options, :dispatcher, Dispatcher)
    }
  end

  @impl Plug
  def call(conn, %{configuration: configuration} = settings) do
    conn
    |> require_route()
    |> require_token(configuration)
    |> require_origin(configuration)
    |> require_json()
    |> handle_message(settings)
  end

  defp require_route(%Plug.Conn{path_info: ["mcp"], method: "POST"} = conn), do: conn

  defp require_route(%Plug.Conn{path_info: ["mcp"]} = conn) do
    reject(conn, 405, @refused, "method not allowed", [{"allow", "POST"}])
  end

  defp require_route(conn), do: reject(conn, 404, @refused, "not found")

  defp require_token(%Plug.Conn{halted: true} = conn, _configuration), do: conn

  defp require_token(conn, configuration) do
    with {:ok, presented} <- bearer_token(conn),
         true <- Configuration.token_matches?(configuration, presented) do
      conn
    else
      _refused -> reject(conn, 401, @refused, "unauthorized", [{"www-authenticate", "Bearer"}])
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, token}
    else
      _other -> :error
    end
  end

  defp require_origin(%Plug.Conn{halted: true} = conn, _configuration), do: conn

  defp require_origin(conn, configuration) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if allowed_origin?(origin, configuration), do: conn, else: forbidden(conn)

      _several ->
        forbidden(conn)
    end
  end

  defp allowed_origin?(origin, configuration) do
    origin in configuration.allowed_origins or loopback_origin?(origin)
  end

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and host in @loopback_hosts ->
        true

      _other ->
        false
    end
  end

  defp forbidden(conn), do: reject(conn, 403, @refused, "forbidden origin")

  defp require_json(%Plug.Conn{halted: true} = conn), do: conn

  defp require_json(conn) do
    with [header] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _parameters} <- Plug.Conn.Utils.media_type(header) do
      conn
    else
      _other -> reject(conn, 415, @refused, "content type must be application/json")
    end
  end

  defp handle_message(%Plug.Conn{halted: true} = conn, _settings), do: conn

  defp handle_message(conn, settings) do
    case read_body(conn, length: @maximum_body_bytes) do
      {:ok, body, conn} ->
        decode_and_dispatch(conn, body, settings)

      {:more, _partial, conn} ->
        reject(conn, 413, @refused, "payload too large")

      {:error, _reason} ->
        reject(conn, 400, @parse_error, "the request body could not be read")
    end
  end

  defp decode_and_dispatch(conn, body, settings) do
    case Protocol.decode(body) do
      {:invalid, :malformed_json} -> reject(conn, 400, @parse_error, "parse error")
      {:invalid, _reason} -> reject(conn, 400, @invalid_request, "invalid request")
      message -> dispatch(conn, message, settings)
    end
  end

  defp dispatch(conn, message, %{configuration: configuration, dispatcher: dispatcher}) do
    context = %{allow_effect: configuration.allow_effect}

    case dispatcher.dispatch(message, context) do
      {:reply, body} -> send_json(conn, 200, body)
      :no_reply -> send_resp(conn, 202, "")
    end
  rescue
    exception -> internal_error(conn, inspect(exception.__struct__))
  catch
    kind, _reason -> internal_error(conn, Atom.to_string(kind))
  end

  defp internal_error(conn, label) do
    Logger.error("MCP server request failed: #{label}")
    reject(conn, 500, @internal_error, "internal error")
  end

  defp reject(conn, status, code, message, headers \\ []) do
    conn
    |> merge_resp_headers(headers)
    |> send_json(status, Protocol.error_response(nil, code, message))
    |> halt()
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
