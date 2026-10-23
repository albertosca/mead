defmodule Mead.MCP.Server.Dispatcher do
  @moduledoc """
  Turns one decoded JSON-RPC message into the server's answer. Pure apart from the tools it
  calls: no HTTP, no process of its own, so every protocol rule is testable without a network.

  It receives what `Mead.MCP.Protocol.decode/1` returns, minus `{:invalid, _}`, which the Plug
  refuses before dispatching. A request gets `{:reply, binary}` (one line of JSON); a
  notification, or a response a client sends back, gets `:no_reply`.

  Protocol faults are JSON-RPC errors: `-32601` for an unknown method and `-32602` for params of
  the wrong type or an unknown tool. A tool that fails while running is not a protocol fault; it
  is a result with `isError: true`.
  """

  alias Mead.MCP.Protocol
  alias Mead.MCP.Server.Tools

  @method_not_found -32_601
  @invalid_params -32_602

  @type context :: %{allow_effect: boolean()}

  @spec dispatch(Protocol.decoded(), context()) :: {:reply, binary()} | :no_reply
  def dispatch({:request, id, method, params}, context) do
    {:reply, answer(method, params, id, context)}
  end

  def dispatch({:notification, _method, _params}, _context), do: :no_reply
  def dispatch({:response, _id, _result}, _context), do: :no_reply
  def dispatch({:error_response, _id, _error}, _context), do: :no_reply

  defp answer("initialize", %{"protocolVersion" => version}, id, _context)
       when is_binary(version) do
    Protocol.result_response(id, %{
      "protocolVersion" => Protocol.protocol_version(),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "mead", "version" => server_version()}
    })
  end

  defp answer("initialize", _params, id, _context) do
    Protocol.error_response(id, @invalid_params, "protocolVersion must be a string")
  end

  defp answer("ping", _params, id, _context), do: Protocol.result_response(id, %{})

  defp answer("tools/list", _params, id, _context) do
    Protocol.result_response(id, %{"tools" => Tools.definitions()})
  end

  defp answer("tools/call", params, id, context) do
    with {:ok, name} <- fetch_name(params),
         {:ok, arguments} <- fetch_arguments(params),
         {:ok, result} <- Tools.call(name, arguments, context) do
      Protocol.result_response(id, result)
    else
      {:error, :unknown_tool} ->
        Protocol.error_response(id, @invalid_params, "unknown tool")

      {:error, {:invalid_params, message}} ->
        Protocol.error_response(id, @invalid_params, message)
    end
  end

  defp answer(_method, _params, id, _context) do
    Protocol.error_response(id, @method_not_found, "method not found")
  end

  defp fetch_name(%{"name" => name}) when is_binary(name), do: {:ok, name}
  defp fetch_name(_params), do: {:error, {:invalid_params, "name must be a string"}}

  defp fetch_arguments(%{"arguments" => arguments}) when is_map(arguments), do: {:ok, arguments}

  defp fetch_arguments(%{"arguments" => _other}) do
    {:error, {:invalid_params, "arguments must be an object"}}
  end

  defp fetch_arguments(_params), do: {:ok, %{}}

  defp server_version do
    case Application.spec(:mead, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end
end
