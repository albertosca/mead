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
    * `:block_binding` - `:drop_block` or `:error`; absent by default.

  `converse_stream/4` is `converse/3` over server-sent events: it calls `on_delta` with each text fragment as it arrives and returns the same result, built by the same parser, so a stream and the equivalent plain body cannot disagree.

  `converse/3` also sends `tools` (omitted from the request when the list is empty) and returns the blocks of the answer; `complete/2` is built on it and keeps returning the joined text. Blocks of type thinking and redacted_thinking are kept verbatim and in order, because the model gets them back in the tool loop and the API checks each one against what preceded it; one that cannot be replayed makes the answer `:malformed_response`, and so does an answer with no text and no tool_use block. Other block types are dropped.

  Requests are retried at most twice, and only after HTTP 429 or a 5xx status. A timeout or a
  transport error is never retried. The key travels only in the request header and is never part
  of a returned reason.

  A refused request still returns `{:http_status, status}`, and the type and message the API gave
  (such as a credit balance that is too low) go to a warning in the log, cut to 500 characters.

  `:block_binding` (`:drop_block` or `:error`) sends the preserved-thinking beta header `thinking-binding-controls-2026-08-01` and sets `thinking.block_binding.prefix_mismatch_behavior`; it is off by default because on an account that is not enforced it turns the check on. Whenever a response reports `input_transformations`, the type, reason and path of each entry go to a warning.
  """

  @behaviour Mead.Provider

  require Logger

  @maximum_logged_message 500
  @maximum_error_body 8_192

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-sonnet-5-5"
  @default_max_tokens 1024
  @default_receive_timeout 25_000
  @default_maximum_retry_delay 2_000
  @default_api_key_file "~/.config/anthropic/api.env"
  @api_key_variable "ANTHROPIC_API_KEY"
  @block_binding_beta "thinking-binding-controls-2026-08-01"
  @block_bindings [:drop_block, :error]

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

  @impl true
  def converse_stream(messages, tools, options, on_delta) when is_function(on_delta, 1) do
    with :ok <- validate_options(options),
         {:ok, api_key} <- fetch_api_key(options),
         {:ok, response} <- stream_request(messages, tools, api_key, options, on_delta) do
      finish_stream(response)
    end
  end

  # A map or any other shape would crash deep inside `Keyword` with the key among the arguments of
  # the stacktrace, which the session stores and replies. Refuse it before the key is read.
  defp validate_options(options) do
    if Keyword.keyword?(options) and Keyword.keyword?(Keyword.get(options, :req_options, [])) and
         valid_block_binding?(options) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp valid_block_binding?(options) do
    not Keyword.has_key?(options, :block_binding) or
      Keyword.fetch!(options, :block_binding) in @block_bindings
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

  defp request(messages, tools, api_key, options),
    do: post(messages, tools, api_key, options, [])

  defp stream_request(messages, tools, api_key, options, on_delta) do
    stream_options = [
      into: fn {:data, data}, {request, response} ->
        {:cont, {request, ingest(response, data, on_delta)}}
      end
    ]

    post(messages, tools, api_key, options, stream_options, true)
  end

  defp post(messages, tools, api_key, options, extra_request_options, stream? \\ false) do
    body =
      %{
        model: Keyword.get(options, :model, @default_model),
        max_tokens: Keyword.get(options, :max_tokens, @default_max_tokens),
        messages: messages
      }
      |> put_tools(tools)
      |> put_stream(stream?)
      |> put_block_binding(Keyword.get(options, :block_binding))

    request_options =
      [
        url: @endpoint,
        json: body,
        headers:
          [{"x-api-key", api_key}, {"anthropic-version", @api_version}] ++
            block_binding_headers(Keyword.get(options, :block_binding)),
        receive_timeout: Keyword.get(options, :receive_timeout, @default_receive_timeout),
        retry: &retry?(&1, &2, maximum_retry_delay(options)),
        max_retries: 2
      ]
      |> Keyword.merge(extra_request_options)
      |> Keyword.merge(Keyword.get(options, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status} = response} -> refused(status, response)
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
      {:error, exception} -> {:error, {:transport, exception.__struct__}}
    end
  end

  # A status alone says 400 for a malformed request and for an empty credit balance alike, so the
  # API's own words go to the log. They never hold the key, which travels only in a header.
  defp refused(status, response) do
    case refusal_body(response) do
      %{"error" => %{"type" => type, "message" => message}}
      when is_binary(type) and is_binary(message) ->
        Logger.warning(
          "Anthropic refused the request with HTTP #{status}: #{type}: " <>
            String.slice(message, 0, @maximum_logged_message)
        )

      _other_body ->
        Logger.warning("Anthropic refused the request with HTTP #{status}")
    end

    {:error, {:http_status, status}}
  end

  # A streamed request collects the body of a failure under :error_body instead of in the body.
  defp refusal_body(%Req.Response{body: %{} = body}), do: body

  defp refusal_body(response) do
    case Jason.decode(Req.Response.get_private(response, :error_body, "")) do
      {:ok, %{} = body} -> body
      _not_json -> nil
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

  defp put_stream(body, true), do: Map.put(body, :stream, true)
  defp put_stream(body, false), do: body

  # Opt-in, because on an account that is not enforced yet the field turns the check on.
  defp put_block_binding(body, nil), do: body

  defp put_block_binding(body, behavior) do
    Map.put(body, :thinking, %{
      type: "adaptive",
      block_binding: %{prefix_mismatch_behavior: Atom.to_string(behavior)}
    })
  end

  defp block_binding_headers(nil), do: []
  defp block_binding_headers(_behavior), do: [{"anthropic-beta", @block_binding_beta}]

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
    warn_transformations(Map.get(body, "input_transformations"))
    stop_reason = stop_reason(Map.get(body, "stop_reason"))

    with {:ok, blocks} <- parse_blocks(content),
         true <- Enum.any?(blocks, &(&1.type in [:text, :tool_use])),
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

  # The API reports here each replayed thinking block it dropped or let through unchecked. Only
  # the entry's type, reason and path are logged: they name a position, never any content.
  defp warn_transformations([_ | _] = entries) do
    described = Enum.map_join(entries, "; ", &describe_transformation/1)

    Logger.warning(
      "Anthropic reported #{length(entries)} replayed thinking block(s) changed: #{described}"
    )
  end

  defp warn_transformations(_none), do: :ok

  defp describe_transformation(%{} = entry) do
    Enum.map_join(["type", "reason", "path"], " ", fn key ->
      case Map.get(entry, key) do
        value when is_binary(value) -> String.slice(value, 0, 100)
        _missing -> "?"
      end
    end)
  end

  defp describe_transformation(_not_a_map), do: "?"

  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason(_other), do: :end_turn

  # Thinking blocks are kept verbatim and in order: the model gets them back in the tool loop, and
  # the API checks each one against everything sent before it. One it cannot replay makes the
  # whole answer malformed, since dropping only that block would leave a gap the check refuses.
  # Blocks of any other type are not requested and are left out.
  defp parse_blocks(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, blocks_reversed} ->
      case parse_block(block) do
        :skip -> {:cont, {:ok, blocks_reversed}}
        :malformed -> {:halt, :malformed}
        parsed -> {:cont, {:ok, [parsed | blocks_reversed]}}
      end
    end)
    |> case do
      {:ok, blocks_reversed} -> {:ok, Enum.reverse(blocks_reversed)}
      :malformed -> :malformed
    end
  end

  defp parse_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %{type: :text, text: text}

  defp parse_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input})
       when is_binary(id) and is_binary(name) and is_map(input),
       do: %{type: :tool_use, id: id, name: name, input: input}

  defp parse_block(%{"type" => "thinking", "thinking" => thinking, "signature" => signature})
       when is_binary(thinking) and is_binary(signature) and signature != "",
       do: %{type: :thinking, thinking: thinking, signature: signature}

  defp parse_block(%{"type" => "redacted_thinking", "data" => data}) when is_binary(data),
    do: %{type: :redacted_thinking, data: data}

  defp parse_block(%{"type" => type}) when type in ["thinking", "redacted_thinking"],
    do: :malformed

  defp parse_block(_other), do: :skip

  # --- streaming ---------------------------------------------------------------------------------
  #
  # The server-sent events are folded into the body a non-streaming call would have returned, and
  # that body goes through `parse/1`, so both paths agree on every edge by construction.

  defp ingest(%Req.Response{status: 200} = response, data, on_delta) do
    state = Req.Response.get_private(response, :stream, new_stream())
    {events, parser} = Mead.Provider.ServerSentEvents.feed(state.parser, data)

    state =
      Enum.reduce(events, %{state | parser: parser}, fn event, current ->
        fold_event(current, event, on_delta)
      end)

    Req.Response.put_private(response, :stream, state)
  end

  # The body of a failed response is not a stream; it is kept, up to a bound, for the log.
  defp ingest(response, data, _on_delta) do
    collected = Req.Response.get_private(response, :error_body, "")

    if byte_size(collected) < @maximum_error_body do
      Req.Response.put_private(response, :error_body, collected <> data)
    else
      response
    end
  end

  defp new_stream do
    %{
      parser: Mead.Provider.ServerSentEvents.new(),
      blocks: %{},
      input_tokens: nil,
      input_transformations: nil,
      output_tokens: nil,
      stop_reason: nil,
      completed: false,
      error: nil,
      malformed: false
    }
  end

  defp fold_event(%{completed: true} = state, _event, _on_delta), do: state
  defp fold_event(%{error: error} = state, _event, _on_delta) when error != nil, do: state

  defp fold_event(state, %{data: data}, on_delta) do
    case Jason.decode(data) do
      {:ok, %{"type" => type} = payload} -> fold(type, payload, state, on_delta)
      _not_an_event -> %{state | malformed: true}
    end
  end

  defp fold("message_start", payload, state, _on_delta) do
    %{
      state
      | input_tokens: get_in(payload, ["message", "usage", "input_tokens"]),
        input_transformations: get_in(payload, ["message", "input_transformations"])
    }
  end

  defp fold(
         "content_block_start",
         %{"index" => index, "content_block" => block},
         state,
         _on_delta
       ) do
    started =
      case block do
        %{"type" => "text"} ->
          %{"type" => "text", "text" => ""}

        %{"type" => "tool_use"} = tool ->
          Map.put(Map.take(tool, ["type", "id", "name"]), "json", "")

        %{"type" => "thinking"} = thinking ->
          Map.merge(
            %{"thinking" => "", "signature" => ""},
            Map.take(thinking, ["type", "thinking", "signature"])
          )

        %{"type" => "redacted_thinking"} = redacted ->
          Map.take(redacted, ["type", "data"])

        other ->
          %{"type" => Map.get(other, "type", "unknown")}
      end

    %{state | blocks: Map.put(state.blocks, index, started)}
  end

  defp fold("content_block_delta", %{"index" => index, "delta" => delta}, state, on_delta) do
    case {Map.get(state.blocks, index), delta} do
      {%{"type" => "text"} = block, %{"type" => "text_delta", "text" => text}}
      when is_binary(text) ->
        if text != "", do: on_delta.(text)
        put_block(state, index, %{block | "text" => block["text"] <> text})

      {%{"type" => "tool_use"} = block, %{"type" => "input_json_delta", "partial_json" => json}}
      when is_binary(json) ->
        put_block(state, index, %{block | "json" => block["json"] <> json})

      {%{"type" => "thinking", "thinking" => thinking} = block,
       %{"type" => "thinking_delta", "thinking" => text}}
      when is_binary(thinking) and is_binary(text) ->
        put_block(state, index, %{block | "thinking" => thinking <> text})

      {%{"type" => "thinking", "signature" => signature} = block,
       %{"type" => "signature_delta", "signature" => more}}
      when is_binary(signature) and is_binary(more) ->
        put_block(state, index, %{block | "signature" => signature <> more})

      _ignored ->
        state
    end
  end

  defp fold("message_delta", payload, state, _on_delta) do
    %{
      state
      | stop_reason: get_in(payload, ["delta", "stop_reason"]) || state.stop_reason,
        output_tokens: get_in(payload, ["usage", "output_tokens"]) || state.output_tokens
    }
  end

  defp fold("message_stop", _payload, state, _on_delta), do: %{state | completed: true}

  defp fold("error", payload, state, _on_delta),
    do: %{state | error: get_in(payload, ["error", "type"]) || "unknown"}

  defp fold(_other_event, _payload, state, _on_delta), do: state

  defp put_block(state, index, block), do: %{state | blocks: Map.put(state.blocks, index, block)}

  defp finish_stream(%Req.Response{status: 200} = response) do
    state = Req.Response.get_private(response, :stream, new_stream())

    cond do
      state.error != nil -> {:error, stream_error(state.error)}
      state.malformed or not state.completed -> {:error, :malformed_response}
      true -> parse(%{response | body: stream_body(state)})
    end
  end

  defp finish_stream(%Req.Response{status: status}), do: {:error, {:http_status, status}}

  defp stream_error("overloaded_error"), do: {:http_status, 529}
  defp stream_error("rate_limit_error"), do: {:http_status, 429}
  defp stream_error(_other), do: {:http_status, 500}

  defp stream_body(state) do
    content =
      state.blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} -> finish_block(block) end)

    %{
      "content" => content,
      "input_transformations" => state.input_transformations,
      "stop_reason" => state.stop_reason,
      "usage" => %{"input_tokens" => state.input_tokens, "output_tokens" => state.output_tokens}
    }
  end

  defp finish_block(%{"type" => "tool_use", "json" => json} = block) do
    input = if json == "", do: {:ok, %{}}, else: Jason.decode(json)

    case input do
      {:ok, decoded} when is_map(decoded) ->
        block |> Map.delete("json") |> Map.put("input", decoded)

      _bad ->
        Map.delete(block, "json")
    end
  end

  defp finish_block(block), do: block
end
