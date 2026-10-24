defmodule Mead.Provider.Anthropic do
  @moduledoc """
  `Mead.Provider` backed by the Anthropic Messages API.

  ## Options

    * `:model` - model identifier; defaults to `"claude-sonnet-5-5"`.
    * `:max_tokens` - upper bound on the reply length; defaults to 1024.
    * `:api_key` - the key itself. When absent, the key is read from `:api_key_file`.
    * `:api_key_file` - a `NAME=value` file holding `ANTHROPIC_API_KEY`; defaults to
      `~/.config/anthropic/api.env`.
    * `:receive_timeout` - milliseconds to wait for the reply; defaults to 25 seconds, below the
      default turn timeout so a slow provider reports its own reason first.
    * `:maximum_retry_delay` - milliseconds; the longest wait before a retry, even when the server
      asks for more with `retry-after`; defaults to 2 seconds.
    * `:req_options` - extra options merged into the `Req` request, used by tests to stub the
      network.

  `converse/3` also sends `tools` (omitted from the request when the list is empty) and returns the blocks of the answer; `complete/2` is built on it and keeps returning the joined text. Blocks other than text and tool_use are dropped.

  Requests are retried at most twice, and only after HTTP 429 or a 5xx status. A timeout or a
  transport error is never retried. The key travels only in the request header and is never part
  of a returned reason.
  """

  @behaviour Mead.Provider

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-sonnet-5-5"
  @default_max_tokens 1024
  @default_receive_timeout 25_000
  @default_maximum_retry_delay 2_000
  @default_api_key_file "~/.config/anthropic/api.env"
  @api_key_variable "ANTHROPIC_API_KEY"

  @impl true
  def complete(messages, options) do
    with {:ok, %{content: content, usage: usage}} <- converse(messages, [], options),
         [_ | _] = texts <- for(%{type: :text, text: text} <- content, do: text) do
      {:ok, %{text: Enum.join(texts), usage: usage}}
    else
      {:error, _reason} = error -> error
      _no_text -> {:error, :malformed_response}
    end
  end

  @impl true
  def converse(messages, tools, options) do
    with :ok <- validate_options(options),
         {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- request(messages, tools, api_key, options) do
      parse(response)
    end
  end

  # A map or any other shape would crash deep inside `Keyword` with the key among the arguments of
  # the stacktrace, which the session stores and replies. Refuse it before the key is read.
  defp validate_options(options) do
    if Keyword.keyword?(options) and Keyword.keyword?(Keyword.get(options, :req_options, [])) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp fetch_api_key(options) do
    case Keyword.get(options, :api_key) do
      api_key when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      _absent ->
        options
        |> Keyword.get(:api_key_file, @default_api_key_file)
        |> read_api_key_file()
    end
  end

  defp read_api_key_file(path) do
    with {:ok, contents} <- File.read(Path.expand(path)),
         api_key when is_binary(api_key) <- find_api_key(contents) do
      {:ok, api_key}
    else
      _missing -> {:error, :missing_api_key}
    end
  end

  defp find_api_key(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [name, value] ->
          if String.trim_leading(name, "export ") |> String.trim() == @api_key_variable do
            value |> String.trim() |> String.trim("\"") |> String.trim("'") |> non_empty()
          end

        _unrelated ->
          nil
      end
    end)
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp request(messages, tools, api_key, options) do
    body =
      %{
        model: Keyword.get(options, :model, @default_model),
        max_tokens: Keyword.get(options, :max_tokens, @default_max_tokens),
        messages: messages
      }
      |> put_tools(tools)

    request_options =
      [
        url: @endpoint,
        json: body,
        headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}],
        receive_timeout: Keyword.get(options, :receive_timeout, @default_receive_timeout),
        retry: &retry?(&1, &2, maximum_retry_delay(options)),
        max_retries: 2
      ]
      |> Keyword.merge(Keyword.get(options, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
      {:error, exception} -> {:error, {:transport, exception.__struct__}}
    end
  end

  defp maximum_retry_delay(options),
    do: Keyword.get(options, :maximum_retry_delay, @default_maximum_retry_delay)

  # A `retry-after` header would otherwise be obeyed in full, and two long waits overrun the turn
  # timeout, so the caller would see `:timeout` instead of the status that caused the retries.
  defp retry?(_request, %Req.Response{status: status} = response, maximum_delay)
       when status == 429 or status >= 500 do
    case Req.Response.get_header(response, "retry-after") do
      [seconds | _rest] ->
        case Integer.parse(seconds) do
          {seconds, ""} -> {:delay, min(seconds * 1_000, maximum_delay)}
          _date_or_garbage -> {:delay, maximum_delay}
        end

      [] ->
        true
    end
  end

  defp retry?(_request, _response_or_exception, _maximum_delay), do: false

  defp put_tools(body, []), do: body
  defp put_tools(body, tools), do: Map.put(body, :tools, Enum.map(tools, &encode_tool/1))

  defp encode_tool(%{name: name, input_schema: input_schema} = tool) do
    base = %{name: name, input_schema: input_schema}

    case Map.get(tool, :description) do
      description when is_binary(description) -> Map.put(base, :description, description)
      _none -> base
    end
  end

  defp parse(%Req.Response{body: %{"content" => content, "usage" => usage} = body})
       when is_list(content) do
    blocks = parse_blocks(content)
    stop_reason = stop_reason(Map.get(body, "stop_reason"))

    with [_ | _] <- blocks,
         true <- stop_reason != :tool_use or Enum.any?(blocks, &(&1.type == :tool_use)),
         %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}
         when is_integer(input_tokens) and is_integer(output_tokens) <- usage do
      {:ok,
       %{
         content: blocks,
         stop_reason: stop_reason,
         usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
       }}
    else
      _malformed -> {:error, :malformed_response}
    end
  end

  defp parse(_response), do: {:error, :malformed_response}

  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason(_other), do: :end_turn

  # Blocks of any other type (thinking, for one) are not requested and are left out.
  defp parse_blocks(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{type: :text, text: text}]

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      when is_binary(id) and is_binary(name) and is_map(input) ->
        [%{type: :tool_use, id: id, name: name, input: input}]

      _other ->
        []
    end)
  end
end
