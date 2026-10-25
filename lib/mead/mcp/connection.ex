defmodule Mead.MCP.Connection do
  @moduledoc """
  One process per configured MCP server. It owns a transport, performs the MCP handshake, keeps
  the server's tools published in `Mead.MCP.Catalog`, and carries tool calls.

  ## Lifecycle

  `:disconnected` -> `:initializing` -> `:listing` -> `:ready`. When the transport cannot start,
  closes, dies, the handshake does not finish in `:handshake_timeout`, or a tool refresh does not
  finish in `:refresh_timeout` (which defaults to the handshake timeout), the connection does not
  crash: it removes its tools from the catalog, fails every pending caller with
  `{:error, :connection_lost}`, stops the transport, and tries again after the next delay of
  `:reconnect_delays` (the last one repeats). A missing command or a server that is down therefore
  costs one retry per delay and never becomes a restart loop that could take the application down.

  Only messages from the current transport are honoured: a late message from a replaced one is
  ignored. The connection traps exits so that a transport that dies is an ordinary event.

  Calls are carried by `call_tool/5`; each pending call monitors its caller and has its own timer.
  """

  use GenServer

  require Logger

  alias Mead.MCP.{Catalog, Protocol}

  @default_handshake_timeout 10_000
  @default_reconnect_delays [1_000, 2_000, 5_000, 15_000, 30_000]
  @maximum_tool_pages 20
  @maximum_result_characters 50_000
  @maximum_description_characters 2_000
  @maximum_schema_bytes 20_000
  @default_schema %{"type" => "object", "properties" => %{}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    server = Keyword.fetch!(options, :server)
    registry = Keyword.fetch!(options, :registry)

    GenServer.start_link(__MODULE__, options, name: {:via, Registry, {registry, server}})
  end

  @spec call_tool(atom(), atom(), String.t(), map(), pos_integer()) ::
          {:ok, %{content: String.t(), is_error: boolean()}} | {:error, term()}
  def call_tool(registry, server, tool, arguments, timeout) do
    case Registry.lookup(registry, server) do
      [{connection, _value}] ->
        try do
          GenServer.call(connection, {:call_tool, tool, arguments, timeout}, timeout + 1_000)
        catch
          :exit, {:timeout, _call} -> {:error, :timeout}
          :exit, _reason -> {:error, :connection_lost}
        end

      [] ->
        {:error, :connection_unavailable}
    end
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    {transport_module, transport_options} = Keyword.fetch!(options, :transport)
    handshake_timeout = Keyword.get(options, :handshake_timeout, @default_handshake_timeout)

    state = %{
      server: Keyword.fetch!(options, :server),
      catalog: Keyword.fetch!(options, :catalog),
      transport_module: transport_module,
      transport_options: transport_options,
      reconnect_delays: Keyword.get(options, :reconnect_delays, @default_reconnect_delays),
      handshake_timeout: handshake_timeout,
      refresh_timeout: Keyword.get(options, :refresh_timeout, handshake_timeout),
      transport: nil,
      phase: :disconnected,
      attempt: 0,
      next_id: 1,
      pending: %{},
      tools: [],
      handshake_reference: nil,
      refresh_reference: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_call(
        {:call_tool, tool, arguments, timeout},
        {caller, _tag} = from,
        %{phase: :ready} = state
      ) do
    monitor = Process.monitor(caller)

    make_pending = fn id ->
      {:call, from, monitor, Process.send_after(self(), {:call_timeout, id}, timeout)}
    end

    {:noreply,
     send_request(state, make_pending, &Protocol.call_tool_request(&1, tool, arguments))}
  end

  def handle_call({:call_tool, _tool, _arguments, _timeout}, _from, state) do
    {:reply, {:error, :connection_unavailable}, state}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_info(:reconnect, %{phase: :disconnected} = state), do: {:noreply, connect(state)}

  def handle_info({:mcp_message, transport, binary}, %{transport: transport} = state) do
    {:noreply, handle_decoded(Protocol.decode(binary), state)}
  end

  def handle_info({:mcp_closed, transport, reason}, %{transport: transport} = state) do
    {:noreply, disconnect(state, {:transport_closed, reason})}
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    {:noreply, disconnect(state, {:transport_exited, reason})}
  end

  def handle_info({:mcp_send_failed, transport, id, reason}, %{transport: transport} = state) do
    {:noreply, fail_request(state, id, {:send_failed, reason})}
  end

  def handle_info({:handshake_timeout, reference}, %{handshake_reference: reference} = state)
      when state.phase in [:initializing, :listing] do
    {:noreply, disconnect(state, :handshake_timeout)}
  end

  def handle_info({:refresh_timeout, reference}, %{refresh_reference: reference} = state),
    do: {:noreply, disconnect(state, :tool_refresh_timeout)}

  def handle_info({:call_timeout, id}, state), do: {:noreply, fail_request(state, id, :timeout)}

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    case Enum.find(state.pending, fn {_id, step} ->
           match?({:call, _from, ^monitor, _timer}, step)
         end) do
      {id, {:call, _from, _monitor, timer}} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_stale_or_unknown, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    stop_transport_and_wait(state.transport)
    Catalog.unregister(state.catalog, state.server)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # The transport cleans up its operating-system child when its owner dies, but when the whole
  # application stops the application master kills what is left without running that cleanup, so
  # the transport is stopped here, while this process can still wait for it.
  defp stop_transport_and_wait(nil), do: :ok

  defp stop_transport_and_wait(transport) do
    GenServer.stop(transport, :shutdown, 3_000)
  catch
    :exit, _reason -> :ok
  end

  # Crash reports and `:sys.get_status/1` print the state, and the transport options can carry an
  # HTTP credential.
  @impl GenServer
  def format_status(%{state: state} = status) do
    redacted = Keyword.replace(state.transport_options, :headers, "[redacted]")
    %{status | state: %{state | transport_options: redacted}}
  end

  # -- connecting --------------------------------------------------------------------------------

  defp connect(state) do
    case state.transport_module.start_link(state.transport_options, self()) do
      {:ok, transport} ->
        reference = make_ref()
        Process.send_after(self(), {:handshake_timeout, reference}, state.handshake_timeout)

        send_request(
          %{state | transport: transport, phase: :initializing, handshake_reference: reference},
          fn _id -> :initialize end,
          &Protocol.initialize_request/1
        )

      {:error, reason} ->
        disconnect(state, {:transport_start_failed, reason})
    end
  end

  defp disconnect(state, reason) do
    Logger.warning("MCP server #{state.server} disconnected: #{inspect(reason)}")

    state = fail_all_pending(state)
    Catalog.unregister(state.catalog, state.server)
    stop_transport(state.transport)

    delay = Enum.at(state.reconnect_delays, state.attempt, List.last(state.reconnect_delays))
    Process.send_after(self(), :reconnect, delay)

    %{
      state
      | transport: nil,
        phase: :disconnected,
        attempt: state.attempt + 1,
        tools: [],
        handshake_reference: nil,
        refresh_reference: nil
    }
  end

  defp stop_transport(nil), do: :ok
  defp stop_transport(transport), do: Process.exit(transport, :shutdown)

  # -- requests ----------------------------------------------------------------------------------

  # `make_pending` receives the id so a call can start its timer with it; the pending entry is
  # recorded before the send, so an answer can never arrive for an id that is not known.
  defp send_request(state, make_pending, build) do
    id = state.next_id
    state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, make_pending.(id))}

    case state.transport_module.send_message(state.transport, id, build.(id)) do
      :ok -> state
      {:error, reason} -> fail_request(state, id, {:send_failed, reason})
    end
  end

  defp fail_request(state, id, reason) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{:call, _from, _monitor, _timer} = call, pending} ->
        reply_to_call(call, {:error, reason})
        %{state | pending: pending}

      {_handshake_step, pending} ->
        disconnect(%{state | pending: pending}, {:handshake_failed, reason})
    end
  end

  defp fail_all_pending(state) do
    for {_id, {:call, _from, _monitor, _timer} = call} <- state.pending do
      reply_to_call(call, {:error, :connection_lost})
    end

    %{state | pending: %{}}
  end

  defp reply_to_call({:call, from, monitor, timer}, outcome) do
    Process.demonitor(monitor, [:flush])
    Process.cancel_timer(timer)
    GenServer.reply(from, outcome)
  end

  # -- incoming messages -------------------------------------------------------------------------

  defp handle_decoded({:response, id, result}, state) do
    with_pending(state, id, fn step, state -> handle_result(step, result, state) end)
  end

  defp handle_decoded({:error_response, id, error}, state) do
    with_pending(state, id, fn step, state -> handle_rpc_error(step, error, state) end)
  end

  defp handle_decoded({:request, id, "ping", _params}, state) do
    answer_server(state, Protocol.result_response(id, %{}))
  end

  defp handle_decoded({:request, id, _method, _params}, state) do
    answer_server(state, Protocol.error_response(id, -32_601, "Method not found"))
  end

  defp handle_decoded(
         {:notification, "notifications/tools/list_changed", _params},
         %{phase: :ready} = state
       ) do
    if Enum.any?(state.pending, fn {_id, step} -> match?({:list_tools, _page}, step) end) do
      state
    else
      start_refresh(state)
    end
  end

  defp handle_decoded(_ignored, state), do: state

  # The handshake has its own timeout; a refresh needs one too (`:refresh_timeout`), because a
  # server that never answers `tools/list` would otherwise leave the catalog stale until the
  # transport happens to drop. Giving up reconnects, which lists the tools again from scratch.
  defp start_refresh(state) do
    reference = make_ref()
    Process.send_after(self(), {:refresh_timeout, reference}, state.refresh_timeout)

    start_listing(%{state | tools: [], refresh_reference: reference}, nil, 1)
  end

  defp with_pending(state, id, function) do
    case Map.pop(state.pending, id) do
      {nil, _pending} -> state
      {step, pending} -> function.(step, %{state | pending: pending})
    end
  end

  defp answer_server(state, message) do
    state.transport_module.send_message(state.transport, nil, message)
    state
  end

  defp handle_result(:initialize, %{"protocolVersion" => version}, state)
       when is_binary(version) do
    if Protocol.supported_version?(version) do
      state.transport_module.send_message(
        state.transport,
        nil,
        Protocol.initialized_notification()
      )

      start_listing(%{state | phase: :listing, tools: []}, nil, 1)
    else
      disconnect(state, {:unsupported_protocol_version, version})
    end
  end

  defp handle_result(:initialize, _result, state),
    do: disconnect(state, :malformed_initialize_response)

  defp handle_result({:list_tools, page}, result, state) do
    case parse_tools(Map.get(result, "tools")) do
      {:ok, tools} ->
        state = %{state | tools: state.tools ++ tools}

        case Map.get(result, "nextCursor") do
          cursor when is_binary(cursor) and cursor != "" and page < @maximum_tool_pages ->
            start_listing(state, cursor, page + 1)

          cursor when is_binary(cursor) and cursor != "" ->
            disconnect(state, :too_many_tool_pages)

          _last_page ->
            publish(state)
        end

      :error ->
        disconnect(state, :malformed_tool_list)
    end
  end

  defp handle_result({:call, _from, _monitor, _timer} = call, result, state) do
    reply_to_call(call, call_outcome(result))
    state
  end

  defp handle_rpc_error({:call, _from, _monitor, _timer} = call, error, state) do
    reply_to_call(call, {:error, {:rpc_error, error.code, error.message}})
    state
  end

  defp handle_rpc_error(_handshake_step, error, state) do
    disconnect(state, {:handshake_rpc_error, error.code})
  end

  # -- tools -------------------------------------------------------------------------------------

  defp start_listing(state, cursor, page) do
    send_request(
      state,
      fn _id -> {:list_tools, page} end,
      &Protocol.list_tools_request(&1, cursor)
    )
  end

  defp parse_tools(tools) when is_list(tools) do
    parsed =
      for %{"name" => name} = tool <- tools, is_binary(name), name != "" do
        %{name: name, description: description(tool), input_schema: input_schema(tool)}
      end

    {:ok, Enum.uniq_by(parsed, & &1.name)}
  end

  defp parse_tools(_not_a_list), do: :error

  # What a server says about a tool goes to the model unchanged, so it is bounded here: a long
  # description is cut, and a schema the provider API would refuse (not an object, or too big) is
  # replaced by the permissive default instead of failing every turn that offers the tool.
  defp description(%{"description" => text}) when is_binary(text),
    do: String.slice(text, 0, @maximum_description_characters)

  defp description(_tool), do: nil

  defp input_schema(%{"inputSchema" => schema}) when is_map(schema) do
    case Map.get(schema, "type") do
      nil -> schema |> Map.put("type", "object") |> within_size_limit()
      "object" -> within_size_limit(schema)
      _other_type -> @default_schema
    end
  end

  defp input_schema(_tool), do: @default_schema

  defp within_size_limit(schema) do
    if byte_size(JSON.encode!(schema)) <= @maximum_schema_bytes, do: schema, else: @default_schema
  end

  defp publish(state) do
    # The deduplication across pages keeps the first tool of a name, as within one page.
    tools = Enum.uniq_by(state.tools, & &1.name)
    :ok = Catalog.register(state.catalog, state.server, self(), tools)

    %{state | phase: :ready, attempt: 0, tools: tools, refresh_reference: nil}
  end

  defp call_outcome(%{"content" => content} = result) when is_list(content) do
    {:ok, %{content: content_text(content), is_error: Map.get(result, "isError") == true}}
  end

  defp call_outcome(_malformed), do: {:error, :malformed_response}

  defp content_text(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => type} when is_binary(type) -> "[non-text content: #{type}]"
      _unknown -> "[non-text content]"
    end)
    |> Enum.join("\n")
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) > @maximum_result_characters do
      String.slice(text, 0, @maximum_result_characters) <>
        "\n[truncated: the result was longer than #{@maximum_result_characters} characters]"
    else
      text
    end
  end
end
