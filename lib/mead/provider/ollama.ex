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
         base_url when is_binary(base_url) and base_url != "" <-
           Keyword.get(options, :base_url, @default_base_url) do
      {:ok,
       %{
         model: model,
         base_url: base_url,
         receive_timeout: Keyword.get(options, :receive_timeout, @default_receive_timeout),
         extra_options: extra_options
       }}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp request(messages, _tools, settings) do
    body = %{model: settings.model, stream: false, messages: encode_messages(messages)}

    request_options =
      [
        url: String.trim_trailing(settings.base_url, "/") <> "/api/chat",
        json: body,
        receive_timeout: settings.receive_timeout,
        retry: false
      ]
      |> Keyword.merge(settings.extra_options)

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
      {:error, exception} -> {:error, {:transport, exception.__struct__}}
    end
  end

  defp encode_messages(messages) do
    for %{role: role, content: content} <- messages do
      %{role: Atom.to_string(role), content: content}
    end
  end

  defp parse(%Req.Response{body: %{"message" => message} = body}) when is_map(message) do
    with {:ok, blocks} <- parse_text(Map.get(message, "content")),
         [_ | _] <- blocks,
         %{"prompt_eval_count" => input_tokens, "eval_count" => output_tokens}
         when is_integer(input_tokens) and is_integer(output_tokens) <- body do
      {:ok,
       %{
         content: blocks,
         stop_reason: :end_turn,
         usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
       }}
    else
      _malformed -> {:error, :malformed_response}
    end
  end

  defp parse(_response), do: {:error, :malformed_response}

  defp parse_text(nil), do: {:ok, []}
  defp parse_text(""), do: {:ok, []}
  defp parse_text(text) when is_binary(text), do: {:ok, [%{type: :text, text: text}]}
  defp parse_text(_other), do: :error
end
