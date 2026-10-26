defmodule Mead.Test.WebSocketClient do
  @moduledoc false

  # A small WebSocket client for the deck tests, on Mint. The functional state is threaded through
  # every call: `receive_json/2` returns the new client with the next decoded message.

  defstruct [:connection, :websocket, :request_reference, frames: [], closed: nil]

  @doc """
  Opens a WebSocket on `path`; `{:error, status, body}` when the server answers anything but 101.
  """
  def connect(port, path, headers \\ []) do
    {:ok, connection} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)

    {:ok, connection, request_reference} = Mint.WebSocket.upgrade(:ws, connection, path, headers)

    case read_upgrade(connection, %{status: nil, headers: [], body: "", done: false}) do
      {:ok, connection, status, headers} ->
        {:ok, connection, websocket} =
          Mint.WebSocket.new(connection, request_reference, status, headers, mode: :passive)

        {:ok,
         %__MODULE__{
           connection: connection,
           websocket: websocket,
           request_reference: request_reference
         }}

      {:refused, status, body} ->
        {:error, status, body}
    end
  end

  # Passive mode, so two clients in one test never read each other's messages from the mailbox.
  defp read_upgrade(connection, collected) do
    case Mint.HTTP.recv(connection, 0, 5_000) do
      {:ok, connection, responses} ->
        collected = Enum.reduce(responses, collected, &collect/2)
        finish_upgrade(connection, collected)

      {:error, _connection, reason, _responses} ->
        {:refused, 0, inspect(reason)}
    end
  end

  defp collect({:status, _reference, status}, collected), do: %{collected | status: status}
  defp collect({:headers, _reference, headers}, collected), do: %{collected | headers: headers}

  defp collect({:data, _reference, data}, collected),
    do: %{collected | body: collected.body <> data}

  defp collect({:done, _reference}, collected), do: %{collected | done: true}

  defp finish_upgrade(connection, %{status: 101, headers: headers, done: true}),
    do: {:ok, connection, 101, headers}

  defp finish_upgrade(_connection, %{status: status, body: body, done: true}),
    do: {:refused, status, body}

  defp finish_upgrade(connection, collected), do: read_upgrade(connection, collected)

  @doc "Sends a frame: `{:text, binary}`, `{:binary, binary}` or `:close`."
  def send_frame(client, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(client.websocket, frame)

    {:ok, connection} =
      Mint.WebSocket.stream_request_body(client.connection, client.request_reference, data)

    %{client | websocket: websocket, connection: connection}
  end

  def send_json(client, map), do: send_frame(client, {:text, JSON.encode!(map)})

  @doc """
  The next frame as `{client, frame}`: `{:text, binary}`, `{:close, code, reason}`, `:closed` once
  the connection is gone, or `:timeout`.
  """
  def receive_frame(%__MODULE__{frames: [frame | rest]} = client, _timeout),
    do: {%{client | frames: rest}, frame}

  def receive_frame(%__MODULE__{closed: closed} = client, _timeout) when closed != nil,
    do: {client, :closed}

  def receive_frame(client, timeout) do
    case Mint.WebSocket.recv(client.connection, 0, timeout) do
      {:ok, connection, responses} ->
        %{client | connection: connection}
        |> absorb(responses)
        |> receive_frame(timeout)

      {:error, connection, :timeout, _responses} ->
        {%{client | connection: connection}, :timeout}

      {:error, connection, _reason, _responses} ->
        receive_frame(%{client | connection: connection, closed: :connection_lost}, timeout)
    end
  end

  defp absorb(client, responses) do
    Enum.reduce(responses, client, fn
      {:data, _reference, data}, client ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(client.websocket, data)
        Enum.reduce(frames, %{client | websocket: websocket}, &accept_frame/2)

      {:done, _reference}, client ->
        %{client | closed: client.closed || :done}

      _other, client ->
        client
    end)
  end

  defp accept_frame({:ping, payload}, client), do: send_frame(client, {:pong, payload})
  defp accept_frame({:pong, _payload}, client), do: client
  defp accept_frame(frame, client), do: %{client | frames: client.frames ++ [frame]}

  @doc "The next text frame decoded as JSON: `{client, map}`, or `{client, other_frame}`."
  def receive_json(client, timeout \\ 2_000) do
    case receive_frame(client, timeout) do
      {client, {:text, text}} -> {client, JSON.decode!(text)}
      {client, other} -> {client, other}
    end
  end

  @doc "Reads frames until one of `type` arrives; raises on a close, a lost connection or a timeout."
  def receive_type(client, type, timeout \\ 2_000) do
    case receive_json(client, timeout) do
      {client, %{"type" => ^type} = envelope} -> {client, envelope}
      {client, %{}} -> receive_type(client, type, timeout)
      {_client, other} -> raise "expected #{type}, got #{inspect(other)}"
    end
  end

  def close(client) do
    Mint.HTTP.close(client.connection)
    :ok
  end
end
