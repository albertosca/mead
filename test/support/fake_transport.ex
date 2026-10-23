defmodule Mead.Test.FakeTransport do
  @moduledoc false

  # A transport the test drives by hand. It reports what the connection sends to the test process
  # named in `:test_pid`, and the test makes it deliver whatever the "server" would say. With
  # `start_error: reason` it refuses to start, so a test can provoke the reconnect path.

  use GenServer

  @behaviour Mead.MCP.Transport

  @impl Mead.MCP.Transport
  def start_link(options, owner) do
    test_pid = Keyword.fetch!(options, :test_pid)

    case Keyword.get(options, :start_error) do
      nil ->
        GenServer.start_link(__MODULE__, {test_pid, owner})

      reason ->
        send(test_pid, {:transport_start_attempted, reason})
        {:error, reason}
    end
  end

  @impl Mead.MCP.Transport
  def send_message(transport, id, message) do
    GenServer.call(transport, {:send, id, message})
  catch
    :exit, _reason -> {:error, :closed}
  end

  def deliver(transport, message), do: GenServer.cast(transport, {:deliver, message})
  def close(transport, reason), do: GenServer.cast(transport, {:close, reason})
  def fail_sends(transport, reason), do: GenServer.call(transport, {:fail_sends, reason})

  @doc "Waits for the next message the connection sent and returns it decoded."
  def next_request(transport, timeout \\ 10_000) do
    receive do
      {:transport_sent, ^transport, _id, message} -> JSON.decode!(message)
    after
      timeout -> raise "the connection sent nothing through the transport within #{timeout} ms"
    end
  end

  @doc "Answers a request the connection sent, with the same id."
  def reply(transport, request, result) do
    deliver(transport, JSON.encode!(%{jsonrpc: "2.0", id: request["id"], result: result}))
  end

  @doc "Plays the server side of initialize, initialized, and one tools/list page."
  def complete_handshake(transport, tools) do
    initialize = next_request(transport)

    reply(transport, initialize, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "fake"}
    })

    initialized = next_request(transport)
    list = next_request(transport)
    reply(transport, list, %{"tools" => tools})

    %{initialize: initialize, initialized: initialized, list: list}
  end

  @impl GenServer
  def init({test_pid, owner}) do
    send(test_pid, {:transport_started, self()})
    {:ok, %{test_pid: test_pid, owner: owner, send_error: nil}}
  end

  @impl GenServer
  def handle_call({:send, id, message}, _from, %{send_error: nil} = state) do
    send(state.test_pid, {:transport_sent, self(), id, message})
    {:reply, :ok, state}
  end

  def handle_call({:send, _id, _message}, _from, state),
    do: {:reply, {:error, state.send_error}, state}

  def handle_call({:fail_sends, reason}, _from, state),
    do: {:reply, :ok, %{state | send_error: reason}}

  @impl GenServer
  def handle_cast({:deliver, message}, state) do
    send(state.owner, {:mcp_message, self(), message})
    {:noreply, state}
  end

  def handle_cast({:close, reason}, state) do
    send(state.owner, {:mcp_closed, self(), reason})
    {:noreply, state}
  end
end
