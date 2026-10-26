defmodule Mead.Provider do
  @moduledoc """
  Behaviour for a model backend that completes a conversation.

  A provider receives the conversation as a list of messages and returns the text of the reply
  together with the token usage, which the token ledger will consume. Failures are returned, not
  raised, as a normalized reason.

  A provider may also export `converse/3`, which lets the model call tools; see that callback.
  """

  @type block ::
          %{type: :text, text: String.t()}
          | %{type: :tool_use, id: String.t(), name: String.t(), input: map()}
          | %{
              type: :tool_result,
              tool_use_id: String.t(),
              content: String.t(),
              is_error: boolean()
            }

  @type message :: %{role: :user | :assistant, content: String.t() | [block()]}

  @type tool :: %{name: String.t(), description: String.t() | nil, input_schema: map()}

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @type reason ::
          :missing_api_key
          | :timeout
          | :malformed_response
          | :invalid_options
          | :tools_unsupported
          | {:http_status, pos_integer()}
          | {:transport, term()}

  @callback complete(messages :: [message()], options :: keyword()) ::
              {:ok, %{text: String.t(), usage: usage()}} | {:error, reason()}

  @doc """
  Like `complete/2`, but the model may ask for tools. It returns the blocks of the answer and why
  the model stopped: `:tool_use` means the blocks include `tool_use` blocks whose results the
  caller must send back in a following call, and `:max_tokens` means the token limit cut the answer
  off. Optional: a provider without it is never given tools.
  """
  @callback converse(messages :: [message()], tools :: [tool()], options :: keyword()) ::
              {:ok,
               %{
                 content: [block()],
                 stop_reason: :end_turn | :tool_use | :max_tokens,
                 usage: usage()
               }}
              | {:error, reason()}

  @doc """
  Like `converse/3`, but the answer streams: `on_delta` is called with each fragment of text as it
  arrives, in order, and the return value is the same as `converse/3` would give for the same
  content. The fragments are a preview; only the return value is the answer. If the stream fails
  midway the error is returned and the fragments already delivered stay delivered. Optional.
  """
  @callback converse_stream(
              messages :: [message()],
              tools :: [tool()],
              options :: keyword(),
              on_delta :: (String.t() -> any())
            ) ::
              {:ok,
               %{
                 content: [block()],
                 stop_reason: :end_turn | :tool_use | :max_tokens,
                 usage: usage()
               }}
              | {:error, reason()}

  @optional_callbacks converse: 3, converse_stream: 4
end
