defmodule Mead.Provider.Ollama do
  @moduledoc """
  `Mead.Provider` backed by the Ollama chat API, meant for the `local` slot of `Mead.Router`.

  ## Options

    * `:model` - the model to run, for example `"llama3.1"`. Required: there is no default, because
      the installed models cannot be known from here. A missing or empty value is `:invalid_options`.
    * `:base_url` - where Ollama listens; defaults to `http://localhost:11434`.
    * `:receive_timeout` - milliseconds to wait for the answer; defaults to 25 seconds, below the
      default turn timeout so a slow server reports its own reason first.
    * `:req_options` - extra options merged into the `Req` request, used by tests to stub the
      network.

  Requests go to `POST {base_url}/api/chat` with `stream: false`, are never retried, and carry no
  credentials. A refused connection is `{:transport, :econnrefused}`, which means Ollama is not
  running.

  `converse/3` also sends `tools` (omitted from the request when the list is empty) in the function form Ollama expects, and returns the text of the answer followed by one `tool_use` block per tool call. Ollama gives a tool call no id, so the provider synthesizes `call_1`, `call_2`, and so on, in order of appearance; a tool result is matched back to its tool name through the assistant message right before it. A model that does not support tools answers HTTP 400, which becomes `:tools_unsupported` when tools were sent; there is no retry without tools, so the turn fails.
  """

  @behaviour Mead.Provider

  @default_base_url "http://localhost:11434"
  @default_receive_timeout 25_000

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
    with {:ok, settings} <- validate_options(options),
         {:ok, response} <- request(messages, tools, settings) do
      parse(response)
    end
  end

  # Anything but a keyword list would crash deep inside `Keyword`, and the model is the one option
  # that cannot be guessed, so all of it is refused before anything is sent.
  defp validate_options(options) do
    with true <- Keyword.keyword?(options),
         extra_options = Keyword.get(options, :req_options, []),
         true <- Keyword.keyword?(extra_options),
         model when is_binary(model) and model != "" <- Keyword.get(options, :model),
         base_url when is_binary(base_url) <- Keyword.get(options, :base_url, @default_base_url),
         true <- http_url?(base_url),
         receive_timeout when is_integer(receive_timeout) and receive_timeout > 0 <-
           Keyword.get(options, :receive_timeout, @default_receive_timeout) do
      {:ok,
       %{
         model: model,
         base_url: base_url,
         receive_timeout: receive_timeout,
         extra_options: extra_options
       }}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  # Ollama's own `OLLAMA_HOST` convention is a bare `127.0.0.1:11434`, which Req refuses by raising.
  defp http_url?(url) do
    match?(
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host not in [nil, ""],
      URI.parse(url)
    )
  end

  defp request(messages, tools, settings) do
    body =
      %{model: settings.model, stream: false, messages: encode_messages(messages)}
      |> put_tools(tools)

    request_options =
      [
        url: String.trim_trailing(settings.base_url, "/") <> "/api/chat",
        json: body,
        receive_timeout: settings.receive_timeout,
        retry: false
      ]
      |> Keyword.merge(settings.extra_options)

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200} = response} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: error_body}} ->
        {:error, failure_reason(status, error_body, tools)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, %{__struct__: Jason.DecodeError}} ->
        {:error, :malformed_response}

      {:error, exception} ->
        {:error, {:transport, exception.__struct__}}
    end
  end

  # The wording is Ollama's, not a stable contract: if it changes, the turn fails with the plain
  # status, which is the safe direction.
  defp failure_reason(400, %{"error" => error}, [_ | _]) when is_binary(error) do
    if String.contains?(error, "does not support tools") do
      :tools_unsupported
    else
      {:http_status, 400}
    end
  end

  defp failure_reason(status, _body, _tools), do: {:http_status, status}

  defp encode_messages(messages) do
    {encoded, _names} = Enum.flat_map_reduce(messages, %{}, &encode_message/2)
    encoded
  end

  defp encode_message(%{role: :assistant, content: content}, _names) when is_binary(content) do
    {[%{role: "assistant", content: content}], %{}}
  end

  defp encode_message(%{role: role, content: content}, names) when is_binary(content) do
    {[%{role: Atom.to_string(role), content: content}], names}
  end

  defp encode_message(%{role: :assistant, content: blocks}, _names) do
    tool_uses = for %{type: :tool_use} = block <- blocks, do: block
    names = Map.new(tool_uses, fn block -> {block.id, block.name} end)
    message = %{role: "assistant", content: join_texts(blocks)}

    case tool_uses do
      [] -> {[message], names}
      _calls -> {[Map.put(message, :tool_calls, Enum.map(tool_uses, &encode_tool_call/1))], names}
    end
  end

  defp encode_message(%{role: :user, content: blocks}, names) do
    texts = join_texts(blocks)
    text_messages = if texts == "", do: [], else: [%{role: "user", content: texts}]
    results = for %{type: :tool_result} = block <- blocks, do: encode_tool_result(block, names)

    {text_messages ++ results, names}
  end

  defp join_texts(blocks), do: for(%{type: :text, text: text} <- blocks, into: "", do: text)

  defp encode_tool_call(%{name: name, input: input}) do
    %{function: %{name: name, arguments: input}}
  end

  defp encode_tool_result(%{tool_use_id: id, content: content}, names) do
    message = %{role: "tool", content: content}

    case Map.fetch(names, id) do
      {:ok, name} -> Map.put(message, :tool_name, name)
      :error -> message
    end
  end

  defp put_tools(body, []), do: body
  defp put_tools(body, tools), do: Map.put(body, :tools, Enum.map(tools, &encode_tool/1))

  defp encode_tool(%{name: name, input_schema: input_schema} = tool) do
    function = %{name: name, parameters: input_schema}

    function =
      case Map.get(tool, :description) do
        description when is_binary(description) -> Map.put(function, :description, description)
        _none -> function
      end

    %{type: "function", function: function}
  end

  defp parse(%Req.Response{body: %{"message" => message} = body}) when is_map(message) do
    with {:ok, text_blocks} <- parse_text(Map.get(message, "content")),
         {:ok, tool_uses} <- parse_tool_calls(Map.get(message, "tool_calls")),
         blocks = text_blocks ++ tool_uses,
         [_ | _] <- blocks,
         %{"prompt_eval_count" => input_tokens, "eval_count" => output_tokens}
         when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
                output_tokens >= 0 <- body do
      {:ok,
       %{
         content: blocks,
         stop_reason: stop_reason(tool_uses, Map.get(body, "done_reason")),
         usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
       }}
    else
      _malformed -> {:error, :malformed_response}
    end
  end

  defp parse(_response), do: {:error, :malformed_response}

  defp stop_reason([], "length"), do: :max_tokens
  defp stop_reason([], _done_reason), do: :end_turn
  defp stop_reason(_tool_uses, _done_reason), do: :tool_use

  defp parse_tool_calls(nil), do: {:ok, []}

  defp parse_tool_calls(calls) when is_list(calls) do
    blocks = calls |> Enum.with_index(1) |> Enum.map(&parse_tool_call/1)

    if Enum.all?(blocks, &match?(%{type: :tool_use}, &1)), do: {:ok, blocks}, else: :error
  end

  defp parse_tool_calls(_other), do: :error

  defp parse_tool_call({%{"function" => %{"name" => name, "arguments" => arguments}}, index})
       when is_binary(name) and name != "" and is_map(arguments) do
    %{type: :tool_use, id: "call_#{index}", name: name, input: arguments}
  end

  defp parse_tool_call(_other), do: :error

  defp parse_text(nil), do: {:ok, []}
  defp parse_text(""), do: {:ok, []}
  defp parse_text(text) when is_binary(text), do: {:ok, [%{type: :text, text: text}]}
  defp parse_text(_other), do: :error
end
