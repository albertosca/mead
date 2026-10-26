defmodule Mead.Deck.Events do
  @moduledoc """
  The wire vocabulary of the deck protocol: building the envelope of a server event and
  validating a client message.

  Pure. A malformed message is an error value, never an exception, because the bytes come from
  a socket and any of them may be garbage.
  """

  @maximum_frame_bytes 65_536
  @maximum_identifier_bytes 128

  @server_event_types ~w(
    session.snapshot prompt.accepted text.delta tool_call.updated permission.requested
    permission.resolved choice.requested choice.resolved metric.updated policy.updated heartbeat
  )

  @policy_levels %{
    "ask_always" => :ask_always,
    "ask_for_risky" => :ask_for_risky,
    "allow_all" => :allow_all
  }

  @type client_message ::
          {:prompt_send, %{client_message_id: String.t(), text: String.t()}}
          | {:permission_respond, %{request_id: String.t(), option_id: String.t()}}
          | {:choice_respond, %{request_id: String.t(), option_id: String.t()}}
          | {:tool_call_cancel, %{tool_call_id: String.t()}}
          | {:session_resume, %{last_sequence: non_neg_integer()}}
          | {:policy_set, %{level: :ask_always | :ask_for_risky | :allow_all}}

  @type decode_error :: :too_large | :not_json | :not_object | :unknown_type | :invalid_payload

  @doc "The largest client frame accepted, in bytes."
  @spec maximum_frame_bytes() :: pos_integer()
  def maximum_frame_bytes, do: @maximum_frame_bytes

  @doc "The names of every event the server sends."
  @spec server_event_types() :: [String.t()]
  def server_event_types, do: @server_event_types

  @spec envelope(non_neg_integer() | nil, String.t(), String.t(), map(), DateTime.t()) :: map()
  def envelope(sequence, session_id, type, payload, %DateTime{} = occurred_at) do
    %{
      "sequence" => sequence,
      "session_id" => session_id,
      "type" => type,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "payload" => payload
    }
  end

  @spec encode(map()) :: binary()
  def encode(envelope), do: JSON.encode!(envelope)

  @spec policy_level_name(atom()) :: String.t()
  def policy_level_name(level) when level in [:ask_always, :ask_for_risky, :allow_all],
    do: Atom.to_string(level)

  @spec parse_policy_level(term()) :: {:ok, atom()} | :error
  def parse_policy_level(name) when is_binary(name), do: Map.fetch(@policy_levels, name)
  def parse_policy_level(_name), do: :error

  @spec decode_client(term()) :: {:ok, client_message()} | {:error, decode_error()}
  def decode_client(frame) when is_binary(frame) and byte_size(frame) > @maximum_frame_bytes,
    do: {:error, :too_large}

  def decode_client(frame) when is_binary(frame) do
    case JSON.decode(frame) do
      {:ok, %{} = message} -> decode_message(message)
      {:ok, _other} -> {:error, :not_object}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  def decode_client(_frame), do: {:error, :not_json}

  defp decode_message(%{"type" => type} = message) when is_binary(type) do
    if type in known_client_types() do
      case Map.get(message, "payload") do
        %{} = payload -> validate(type, payload)
        _other -> {:error, :invalid_payload}
      end
    else
      {:error, :unknown_type}
    end
  end

  defp decode_message(_message), do: {:error, :unknown_type}

  defp known_client_types do
    ~w(prompt.send permission.respond choice.respond tool_call.cancel session.resume policy.set)
  end

  defp validate("prompt.send", %{"client_message_id" => id, "text" => text}) do
    with {:ok, id} <- identifier(id),
         true <- is_binary(text) and String.trim(text) != "" do
      {:ok, {:prompt_send, %{client_message_id: id, text: text}}}
    else
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp validate("permission.respond", %{"request_id" => request_id, "option_id" => option_id}),
    do: respond(:permission_respond, request_id, option_id)

  defp validate("choice.respond", %{"request_id" => request_id, "option_id" => option_id}),
    do: respond(:choice_respond, request_id, option_id)

  defp validate("tool_call.cancel", %{"tool_call_id" => tool_call_id}) do
    case identifier(tool_call_id) do
      {:ok, id} -> {:ok, {:tool_call_cancel, %{tool_call_id: id}}}
      :error -> {:error, :invalid_payload}
    end
  end

  defp validate("session.resume", %{"last_sequence" => last_sequence})
       when is_integer(last_sequence) and last_sequence >= 0,
       do: {:ok, {:session_resume, %{last_sequence: last_sequence}}}

  defp validate("policy.set", %{"level" => level}) do
    case parse_policy_level(level) do
      {:ok, parsed} -> {:ok, {:policy_set, %{level: parsed}}}
      :error -> {:error, :invalid_payload}
    end
  end

  defp validate(_type, _payload), do: {:error, :invalid_payload}

  defp respond(tag, request_id, option_id) do
    with {:ok, request_id} <- identifier(request_id),
         {:ok, option_id} <- identifier(option_id) do
      {:ok, {tag, %{request_id: request_id, option_id: option_id}}}
    else
      :error -> {:error, :invalid_payload}
    end
  end

  defp identifier(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_identifier_bytes,
       do: {:ok, value}

  defp identifier(_value), do: :error
end
