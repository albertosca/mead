defmodule Mead.MCP.Transport.Stdio do
  @moduledoc """
  Runs an MCP server as a child process and talks to it over its standard input and output, one
  JSON message per line.

  ## Options

    * `:command` - the executable, looked up on the `PATH` (required).
    * `:arguments` - a list of binaries; defaults to `[]`.
    * `:maximum_message_bytes` - the longest message accepted; defaults to 4 MiB. A longer one
      closes the transport with `:message_too_large` instead of growing without bound.
    * `:exit_grace_milliseconds` - how long a child gets to leave after its stdin closes before it
      is sent `SIGTERM`; defaults to 1 000. A child that is still alive 500 ms after `SIGTERM`
      receives `SIGKILL`.

  The child's standard error is not read: it goes to the terminal of the Erlang VM, which keeps
  the progress chatter that tools such as `npx` print out of the protocol stream.

  `Port.close/1` does not end the child, so stopping this transport closes stdin (which makes a
  well-behaved server exit) and then signals the child that stays. A server started through a
  wrapper such as `npx` may leave a grandchild that shares the wrapper's stdin and ends with it;
  a grandchild that ignores stdin closing is not tracked.
  """

  use GenServer

  @behaviour Mead.MCP.Transport

  @default_maximum_message_bytes 4_194_304
  @default_exit_grace_milliseconds 1_000
  @kill_grace_milliseconds 500
  @port_line_bytes 65_536

  @impl Mead.MCP.Transport
  def start_link(options, owner) when is_list(options) and is_pid(owner) do
    with {:ok, executable} <- find_executable(options) do
      GenServer.start_link(__MODULE__, {executable, options, owner})
    end
  end

  @impl Mead.MCP.Transport
  def send_message(transport, _id, message) when is_binary(message) do
    GenServer.call(transport, {:send, message})
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp find_executable(options) do
    case Keyword.get(options, :command) do
      command when is_binary(command) and command != "" ->
        case System.find_executable(command) do
          nil -> {:error, {:command_not_found, command}}
          executable -> {:ok, executable}
        end

      _invalid ->
        {:error, :invalid_command}
    end
  end

  @impl GenServer
  def init({executable, options, owner}) do
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, @port_line_bytes},
        {:args, Keyword.get(options, :arguments, [])}
      ])

    {:ok,
     %{
       owner: owner,
       port: port,
       os_pid: os_pid(port),
       partial: [],
       partial_bytes: 0,
       maximum_message_bytes:
         Keyword.get(options, :maximum_message_bytes, @default_maximum_message_bytes),
       exit_grace_milliseconds:
         Keyword.get(options, :exit_grace_milliseconds, @default_exit_grace_milliseconds)
     }}
  rescue
    error in ErlangError -> {:stop, {:spawn_failed, error.original}}
  end

  # A child that exits at once may already be gone when the port is asked for its pid.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _closed -> nil
    end
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when is_port(port) do
    {:reply, write(port, message), state}
  end

  def handle_call({:send, _message}, _from, state), do: {:reply, {:error, :closed}, state}

  defp write(port, message) do
    Port.command(port, [message, "\n"])
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    bytes = state.partial_bytes + byte_size(chunk)

    if bytes > state.maximum_message_bytes do
      close_with(:message_too_large, state)
    else
      {:noreply, %{state | partial: [state.partial, chunk], partial_bytes: bytes}}
    end
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    bytes = state.partial_bytes + byte_size(line)

    if bytes > state.maximum_message_bytes do
      close_with(:message_too_large, state)
    else
      case IO.iodata_to_binary([state.partial, line]) do
        "" -> :ok
        message -> send(state.owner, {:mcp_message, self(), message})
      end

      {:noreply, %{state | partial: [], partial_bytes: 0}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:mcp_closed, self(), {:exit_status, status}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    send(state.owner, {:mcp_closed, self(), {:port_exit, reason}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp close_with(reason, state) do
    send(state.owner, {:mcp_closed, self(), reason})
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port} = state) when is_port(port) do
    close(port)
    stop_child(state.os_pid, state.exit_grace_milliseconds)
  end

  def terminate(_reason, _state), do: :ok

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp stop_child(nil, _grace), do: :ok

  defp stop_child(os_pid, grace) do
    unless exited_within?(os_pid, grace) do
      signal(os_pid, "TERM")
      unless exited_within?(os_pid, @kill_grace_milliseconds), do: signal(os_pid, "KILL")
    end

    :ok
  end

  defp exited_within?(os_pid, milliseconds) do
    wait_for_exit(os_pid, System.monotonic_time(:millisecond) + milliseconds)
  end

  defp wait_for_exit(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        wait_for_exit(os_pid, deadline)
    end
  end

  defp alive?(os_pid) do
    match?(
      {_output, 0},
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    )
  end

  defp signal(os_pid, name) do
    System.cmd("kill", ["-" <> name, Integer.to_string(os_pid)], stderr_to_stdout: true)
  end
end
