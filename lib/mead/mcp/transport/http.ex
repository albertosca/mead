defmodule Mead.MCP.Transport.Http do
  @moduledoc """
  The Streamable HTTP transport of MCP: every message is a POST, and the answer is either one
  JSON body or an event stream that ends with the answer.

  ## Options

    * `:url` - `http://` or `https://` endpoint (required).
    * `:headers` - a list of `{name, value}` binaries sent on every request, for credentials.
    * `:receive_timeout` - milliseconds to wait for an answer; defaults to 30 000.
    * `:req_options` - extra options merged into every `Req` request, used by tests to stub the
      network.

  Each POST runs in its own task, so a slow answer never blocks another request. The whole
  response is read before it is decoded, which is why no incremental delivery is needed from
  `Req`. The server may assign a session id in the `mcp-session-id` header; it is echoed on every
  later request, and a 404 after a session was assigned means the session expired, which closes
  the transport so the connection starts over.

  Not verified against a real remote server: only against a `Plug` double. Reasons never contain
  the configured headers.
  """

  use GenServer

  @behaviour Mead.MCP.Transport

  alias Mead.MCP.Protocol

  @default_receive_timeout 30_000

  @impl Mead.MCP.Transport
  def start_link(options, owner) when is_list(options) and is_pid(owner) do
    url = Keyword.get(options, :url)

    if is_binary(url) and String.starts_with?(url, ["http://", "https://"]) do
      GenServer.start_link(__MODULE__, {options, owner})
    else
      {:error, :invalid_url}
    end
  end

  @impl Mead.MCP.Transport
  def send_message(transport, id, message) when is_binary(message) do
    GenServer.call(transport, {:send, id, message})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl GenServer
  def init({options, owner}) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       owner: owner,
       task_supervisor: task_supervisor,
       url: Keyword.fetch!(options, :url),
       headers: Keyword.get(options, :headers, []),
       receive_timeout: Keyword.get(options, :receive_timeout, @default_receive_timeout),
       req_options: Keyword.get(options, :req_options, []),
       session_id: nil
     }}
  end

  @impl GenServer
  def handle_call({:send, id, message}, _from, state) do
    transport = self()
    request = build_request(state, message)

    {:ok, _task} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        send(transport, {:http_result, id, perform(request)})
      end)

    {:reply, :ok, state}
  end

  # An exception inside the task would leave the request unanswered until the connection's own
  # timeout, so it is turned into the same kind of result a transport error produces.
  defp perform(request) do
    Req.post(request)
  rescue
    exception -> {:error, exception}
  end

  defp build_request(state, message) do
    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", Protocol.protocol_version()}
      ] ++ session_header(state) ++ state.headers

    Keyword.merge(
      [
        url: state.url,
        body: message,
        headers: headers,
        receive_timeout: state.receive_timeout,
        decode_body: false,
        retry: false
      ],
      state.req_options
    )
  end

  defp session_header(%{session_id: nil}), do: []
  defp session_header(%{session_id: session_id}), do: [{"mcp-session-id", session_id}]

  @impl GenServer
  def handle_info({:http_result, id, {:ok, %Req.Response{status: status} = response}}, state)
      when status in 200..299 do
    state = remember_session(state, response)
    deliver(state, id, response)
    {:noreply, state}
  end

  def handle_info(
        {:http_result, _id, {:ok, %Req.Response{status: 404}}},
        %{session_id: session_id} = state
      )
      when is_binary(session_id) do
    send(state.owner, {:mcp_closed, self(), :session_expired})
    {:stop, :normal, state}
  end

  def handle_info({:http_result, id, {:ok, %Req.Response{status: status}}}, state) do
    fail(state, id, {:http_status, status})
    {:noreply, state}
  end

  def handle_info({:http_result, id, {:error, %Req.TransportError{reason: :timeout}}}, state) do
    fail(state, id, :timeout)
    {:noreply, state}
  end

  def handle_info({:http_result, id, {:error, %Req.TransportError{reason: reason}}}, state) do
    fail(state, id, {:transport, reason})
    {:noreply, state}
  end

  def handle_info({:http_result, id, {:error, exception}}, state) do
    fail(state, id, {:transport, exception.__struct__})
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp remember_session(state, response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _rest] -> %{state | session_id: session_id}
      [] -> state
    end
  end

  defp deliver(_state, _id, %Req.Response{status: 202}), do: :ok
  defp deliver(_state, _id, %Req.Response{body: body}) when body in ["", nil], do: :ok

  defp deliver(state, id, %Req.Response{body: body} = response) do
    content_type = response |> Req.Response.get_header("content-type") |> List.first("")

    cond do
      String.contains?(content_type, "application/json") ->
        send(state.owner, {:mcp_message, self(), body})

      String.contains?(content_type, "text/event-stream") ->
        for data <- event_data(body), do: send(state.owner, {:mcp_message, self(), data})

      true ->
        fail(state, id, {:unexpected_content_type, content_type})
    end

    :ok
  end

  defp event_data(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n", trim: true)
    |> Enum.map(&data_of_event/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp data_of_event(event) do
    event
    |> String.split("\n")
    |> Enum.flat_map(fn
      "data: " <> data -> [data]
      "data:" <> data -> [data]
      _other_field -> []
    end)
    |> Enum.join("\n")
  end

  defp fail(state, id, reason) do
    send(state.owner, {:mcp_send_failed, self(), id, reason})
  end
end
