defmodule Mead.Test.SseClient do
  @moduledoc false

  # A small Server-Sent Events client for the deck tests, on Mint in passive mode. The functional
  # state is threaded through every call: `receive_event/2` returns the new client with the next
  # event, parsed into `%{event: name | nil, id: string | nil, data: string}`.

  defstruct [:connection, :request_reference, :status, headers: [], buffer: "", done: false]

  @doc "Opens `path` and waits for the status line and headers; the body is read afterwards."
  def connect(port, path, headers \\ []) do
    {:ok, connection} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)

    {:ok, connection, request_reference} =
      Mint.HTTP.request(connection, "GET", path, [{"accept", "text/event-stream"} | headers], nil)

    read_head(%__MODULE__{connection: connection, request_reference: request_reference})
  end

  defp read_head(%__MODULE__{status: status, headers: headers} = client)
       when status != nil and headers != [],
       do: {:ok, client}

  defp read_head(client) do
    case Mint.HTTP.recv(client.connection, 0, 5_000) do
      {:ok, connection, responses} ->
        read_head(absorb(%{client | connection: connection}, responses))

      {:error, _connection, reason, _responses} ->
        {:error, reason}
    end
  end

  @doc "The value of a response header, or nil."
  def header(client, name) do
    Enum.find_value(client.headers, fn {key, value} -> if key == name, do: value end)
  end

  @doc """
  The next event as `{client, event}`; `:timeout` when none arrived in time, `:closed` once the
  server has ended the stream and nothing is left to read. Comments (`: ...`) are skipped.
  """
  def receive_event(client, timeout \\ 10_000) do
    case take_event(client.buffer) do
      {:ok, event, rest} ->
        {%{client | buffer: rest}, event}

      :none ->
        read_more(client, timeout)
    end
  end

  defp read_more(%__MODULE__{done: true} = client, _timeout), do: {client, :closed}

  defp read_more(client, timeout) do
    case Mint.HTTP.recv(client.connection, 0, timeout) do
      {:ok, connection, responses} ->
        %{client | connection: connection} |> absorb(responses) |> receive_event(timeout)

      {:error, connection, %Mint.TransportError{reason: :timeout}, _responses} ->
        {%{client | connection: connection}, :timeout}

      {:error, connection, _reason, _responses} ->
        {%{client | connection: connection, done: true}, :closed}
    end
  end

  @doc "The next event, with its data decoded as JSON: `{client, event_with_map_data}`."
  def receive_json(client, timeout \\ 10_000) do
    case receive_event(client, timeout) do
      {client, %{data: data} = event} -> {client, %{event | data: JSON.decode!(data)}}
      other -> other
    end
  end

  @doc "Reads events until an unnamed one whose envelope has `type`; raises on close or timeout."
  def receive_type(client, type, timeout \\ 10_000) do
    case receive_json(client, timeout) do
      {client, %{event: nil, data: %{"type" => ^type}} = event} -> {client, event}
      {client, %{}} -> receive_type(client, type, timeout)
      {_client, other} -> raise "expected #{type}, got #{inspect(other)}"
    end
  end

  def close(client) do
    Mint.HTTP.close(client.connection)
    :ok
  end

  defp absorb(client, responses) do
    Enum.reduce(responses, client, fn
      {:status, _reference, status}, client -> %{client | status: status}
      {:headers, _reference, headers}, client -> %{client | headers: client.headers ++ headers}
      {:data, _reference, data}, client -> %{client | buffer: client.buffer <> data}
      {:done, _reference}, client -> %{client | done: true}
      _other, client -> client
    end)
  end

  defp take_event(buffer) do
    case String.split(buffer, "\n\n", parts: 2) do
      [block, rest] ->
        case parse_block(block) do
          nil -> take_event(rest)
          event -> {:ok, event, rest}
        end

      [_incomplete] ->
        :none
    end
  end

  defp parse_block(block) do
    fields =
      block
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ":")))
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> {name, String.trim_leading(value, " ")}
          [name] -> {name, ""}
        end
      end)

    case fields do
      [] ->
        nil

      fields ->
        %{
          event: field(fields, "event"),
          id: field(fields, "id"),
          data: for({"data", value} <- fields, do: value) |> Enum.join("\n")
        }
    end
  end

  defp field(fields, name),
    do: Enum.find_value(fields, fn {key, value} -> if key == name, do: value end)
end
