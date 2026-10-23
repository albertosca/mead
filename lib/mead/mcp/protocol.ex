defmodule Mead.MCP.Protocol do
  @moduledoc """
  Pure JSON-RPC 2.0 codec for the slice of MCP that `mead` speaks as a client: `initialize`,
  `notifications/initialized`, `tools/list`, and `tools/call`.

  Encoders return one-line JSON binaries (the JSON encoder escapes newlines inside strings), so a
  stdio transport can frame messages with a trailing newline. `decode/1` never raises.
  """

  @protocol_version "2025-06-18"

  @type request_id :: integer() | String.t()

  @type decoded ::
          {:response, request_id(), map()}
          | {:error_response, request_id(), %{code: integer(), message: String.t(), data: term()}}
          | {:request, request_id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:invalid,
             :not_binary | :malformed_json | :not_jsonrpc | :result_and_error | :unrecognized}

  @doc "The one protocol version this client negotiates."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @spec supported_version?(term()) :: boolean()
  def supported_version?(version), do: version == @protocol_version

  @spec initialize_request(request_id()) :: binary()
  def initialize_request(id) do
    request(id, "initialize", %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "mead", "version" => client_version()}
    })
  end

  @spec initialized_notification() :: binary()
  def initialized_notification do
    JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
  end

  @spec list_tools_request(request_id(), String.t() | nil) :: binary()
  def list_tools_request(id, cursor \\ nil)
  def list_tools_request(id, nil), do: request(id, "tools/list", %{})
  def list_tools_request(id, cursor), do: request(id, "tools/list", %{"cursor" => cursor})

  @spec call_tool_request(request_id(), String.t(), map()) :: binary()
  def call_tool_request(id, name, arguments) do
    request(id, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  @spec result_response(request_id(), map()) :: binary()
  def result_response(id, result) do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @spec error_response(request_id() | nil, integer(), String.t()) :: binary()
  def error_response(id, code, message) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  @spec decode(term()) :: decoded()
  def decode(input) when not is_binary(input), do: {:invalid, :not_binary}

  def decode(input) do
    case JSON.decode(input) do
      {:ok, %{"jsonrpc" => "2.0"} = message} -> classify(message)
      {:ok, _other} -> {:invalid, :not_jsonrpc}
      {:error, _reason} -> {:invalid, :malformed_json}
    end
  end

  defp request(id, method, params) do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp classify(%{"result" => _result, "error" => _error}), do: {:invalid, :result_and_error}

  defp classify(%{"id" => id, "result" => result}) when is_map(result) do
    if valid_id?(id), do: {:response, id, result}, else: {:invalid, :unrecognized}
  end

  defp classify(%{"id" => id, "error" => %{"code" => code, "message" => message} = error})
       when is_integer(code) and is_binary(message) do
    if valid_id?(id) do
      {:error_response, id, %{code: code, message: message, data: Map.get(error, "data")}}
    else
      {:invalid, :unrecognized}
    end
  end

  defp classify(%{"id" => id, "method" => method} = message) when is_binary(method) do
    if valid_id?(id), do: {:request, id, method, params(message)}, else: {:invalid, :unrecognized}
  end

  defp classify(%{"method" => method} = message) when is_binary(method) do
    if Map.has_key?(message, "id") do
      {:invalid, :unrecognized}
    else
      {:notification, method, params(message)}
    end
  end

  defp classify(_message), do: {:invalid, :unrecognized}

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_message), do: %{}

  defp valid_id?(id), do: is_integer(id) or is_binary(id)

  defp client_version do
    case Application.spec(:mead, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end
end
