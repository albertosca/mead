defmodule Mead.Provider do
  @moduledoc """
  Behaviour for a model backend that completes a conversation.

  A provider receives the conversation as a list of messages and returns the text of the reply
  together with the token usage, which the token ledger will consume. Failures are returned, not
  raised, as a normalized reason.
  """

  @type message :: %{role: :user | :assistant, content: String.t()}

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @type reason ::
          :missing_api_key
          | :timeout
          | :malformed_response
          | :invalid_options
          | {:http_status, pos_integer()}
          | {:transport, term()}

  @callback complete(messages :: [message()], options :: keyword()) ::
              {:ok, %{text: String.t(), usage: usage()}} | {:error, reason()}
end
