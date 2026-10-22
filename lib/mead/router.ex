defmodule Mead.Router do
  @moduledoc """
  Turn handler that sends each turn to a local or a cloud model.

  The route is the one forced with `Mead.submit_turn/3` (`route: :local` or `route: :cloud`) or,
  for `route: :auto`, the one `Mead.Router.Classifier` picks. The route names a slot, and each
  slot holds a `{provider_module, provider_options}` pair implementing `Mead.Provider`, read from
  the application environment:

      config :mead, :router,
        slots: [
          local: nil,
          cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
        ]

  A turn routed to an empty slot fails with `:local_unavailable` or `:cloud_unavailable` and
  nothing is sent anywhere. In particular a turn meant for the local model is never sent to the
  cloud on its own.

  ## Tools

  When the route is `:cloud`, the provider exports `converse/3`, and `Mead.MCP.Hub.tools_for/1`
  shows at least one tool for the turn, the turn becomes a loop: the model answers or asks for
  tools, each requested call goes to `Mead.MCP.Hub.call_tool/3`, and the results are sent back,
  until the model answers with text. The loop stops after eight provider calls with
  `:tool_loop_limit`. A tool that fails, is not allowed, or does not exist is reported to the
  model as an error result and is never retried; the turn does not fail for it. The turn option
  `tools: :effect` also shows tools that have side effects; see `Mead.MCP.Policy`. The whole loop
  runs inside the turn timeout, so a conversation that uses tools may need a larger
  `:turn_timeout` than the default of 30 seconds.

  The router keeps no state, so every conversation stays independent of the others. Each turn
  emits `[:mead, :router, :route]` with the measurements `duration` (in native time units),
  `input_tokens`, and `output_tokens` (summed over every provider call of the turn, and zero when
  the first call failed), and `tool_calls` (how many tool calls the model asked for), and the
  metadata `route`, `route_source` (`:classified` or `:forced`), `provider` (the module, or `nil`
  for an empty slot), `status` (`:ok` or `:error`), and `session_id` (the session the server
  passed in the options, `nil` outside a session). A provider that raises instead of returning
  an error emits no event.
  """

  @behaviour Mead.Session.TurnHandler

  alias Mead.Router.Classifier
  alias Mead.Session.Turn

  @event [:mead, :router, :route]
  # A conversation that grows without bound eventually overflows the model's context and then
  # every later turn fails, so only the most recent exchanges are replayed.
  @maximum_replayed_exchanges 20
  # A model that keeps asking for tools would otherwise spend the turn timeout and the budget.
  @maximum_provider_calls 8

  @impl true
  def handle_turn(history, input, options) do
    slots =
      :mead
      |> Application.get_env(:router, [])
      |> Keyword.get(:slots, [])

    route(history, input, options, slots)
  end

  @doc """
  Routes one turn through the given `slots`, with tools from `hub`.

  `handle_turn/3` is this function with the slots read from the application environment and the
  default hub; it exists separately so tests can pass their own slots and hub without touching
  global state. A caller of `Mead.submit_turn/3` cannot choose the hub.
  """
  @spec route([Turn.t()], term(), keyword(), keyword(), module()) ::
          {:ok, String.t()} | {:error, term()}
  def route(history, input, options, slots, hub \\ Mead.MCP.Hub) do
    started_at = System.monotonic_time()
    {route, route_source} = choose_route(history, input, options)
    slot = if Keyword.keyword?(slots), do: Keyword.get(slots, route), else: :invalid

    outcome = call_slot(slot, route, history, input, options, hub)

    :telemetry.execute(
      @event,
      %{
        duration: System.monotonic_time() - started_at,
        input_tokens: outcome.usage.input_tokens,
        output_tokens: outcome.usage.output_tokens,
        tool_calls: outcome.tool_calls
      },
      %{
        route: route,
        route_source: route_source,
        provider: outcome.provider,
        status: if(match?({:ok, _text}, outcome.result), do: :ok, else: :error),
        session_id: Keyword.get(options, :session_id)
      }
    )

    outcome.result
  end

  defp choose_route(history, input, options) do
    case Keyword.get(options, :route, :auto) do
      :auto -> {Classifier.classify(history, input), :classified}
      forced -> {forced, :forced}
    end
  end

  defp outcome(result, provider, usage \\ no_usage(), tool_calls \\ 0) do
    %{result: result, provider: provider, usage: usage, tool_calls: tool_calls}
  end

  defp call_slot(nil, route, _history, _input, _options, _hub) do
    outcome({:error, unavailable_reason(route)}, nil)
  end

  # A slot of any other shape would crash inside the provider with its content in the stacktrace,
  # which the session stores and replies; refuse it by shape instead.
  defp call_slot({provider, provider_options} = slot, route, history, input, options, hub) do
    if is_atom(provider) and Keyword.keyword?(provider_options) do
      call_provider(slot, route, history, input, options, hub)
    else
      outcome({:error, :invalid_slot}, nil)
    end
  end

  defp call_slot(_invalid, _route, _history, _input, _options, _hub) do
    outcome({:error, :invalid_slot}, nil)
  end

  defp call_provider({provider, provider_options}, route, history, input, options, hub) do
    if is_binary(input) and String.valid?(input) do
      messages = build_messages(history, input)

      case tools_for_turn(provider, route, options, hub) do
        [] -> complete_once(provider, provider_options, messages)
        tools -> converse_loop(provider, provider_options, messages, tools, options, hub)
      end
    else
      outcome({:error, :unsupported_input}, provider)
    end
  end

  defp complete_once(provider, provider_options, messages) do
    case provider.complete(messages, provider_options) do
      {:ok, %{text: text, usage: usage}} -> outcome({:ok, text}, provider, usage)
      {:error, reason} -> outcome({:error, reason}, provider)
    end
  end

  # Only the cloud route is offered tools, and only through a provider that can carry them.
  defp tools_for_turn(provider, :cloud, options, hub) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :converse, 3) do
      hub.tools_for(options)
    else
      []
    end
  end

  defp tools_for_turn(_provider, _route, _options, _hub), do: []

  defp converse_loop(provider, provider_options, messages, tools, options, hub) do
    context = %{
      provider: provider,
      provider_options: provider_options,
      tools: tools,
      options: options,
      hub: hub
    }

    {result, progress} = loop(context, messages, %{calls: 0, tool_calls: 0, usage: no_usage()})
    outcome(result, provider, progress.usage, progress.tool_calls)
  end

  defp loop(_context, _messages, %{calls: calls} = progress)
       when calls >= @maximum_provider_calls do
    {{:error, :tool_loop_limit}, progress}
  end

  defp loop(context, messages, progress) do
    case context.provider.converse(messages, context.tools, context.provider_options) do
      {:ok, %{content: content, stop_reason: :tool_use, usage: usage}} ->
        progress = add_call(progress, usage)

        case for(%{type: :tool_use} = block <- content, do: block) do
          [] ->
            {{:error, :malformed_response}, progress}

          tool_uses ->
            results = Enum.map(tool_uses, &run_tool(context, &1))

            messages =
              messages ++
                [%{role: :assistant, content: content}, %{role: :user, content: results}]

            loop(context, messages, %{
              progress
              | tool_calls: progress.tool_calls + length(tool_uses)
            })
        end

      {:ok, %{content: content, usage: usage}} ->
        progress = add_call(progress, usage)

        case for(%{type: :text, text: text} <- content, do: text) do
          [] -> {{:error, :malformed_response}, progress}
          texts -> {{:ok, Enum.join(texts)}, progress}
        end

      {:error, reason} ->
        {{:error, reason}, progress}
    end
  end

  defp add_call(progress, usage) do
    %{
      progress
      | calls: progress.calls + 1,
        usage: %{
          input_tokens: progress.usage.input_tokens + usage.input_tokens,
          output_tokens: progress.usage.output_tokens + usage.output_tokens
        }
    }
  end

  defp run_tool(context, %{id: id, name: name, input: input}) do
    {content, is_error} =
      case context.hub.call_tool(name, input, context.options) do
        {:ok, %{content: content, is_error: is_error}} -> {content, is_error}
        {:error, reason} -> {"The tool call failed: #{describe(reason)}.", true}
      end

    %{type: :tool_result, tool_use_id: id, content: content, is_error: is_error}
  end

  defp describe(:unknown_tool), do: "unknown tool"
  defp describe(:not_allowed), do: "this tool is not allowed in this turn"
  defp describe(:timeout), do: "it took too long"
  defp describe(:connection_lost), do: "the connection to the tool server was lost"
  defp describe(:connection_unavailable), do: "the tool server is not connected"
  defp describe(:invalid_arguments), do: "the arguments were not an object"
  defp describe({:rpc_error, _code, message}), do: "the tool server answered: #{message}"
  defp describe(other), do: inspect(other)

  defp unavailable_reason(:local), do: :local_unavailable
  defp unavailable_reason(:cloud), do: :cloud_unavailable

  defp no_usage, do: %{input_tokens: 0, output_tokens: 0}

  # Only completed text exchanges teach the model anything: failed, timed-out, and interrupted
  # turns, and turns whose input or output is not text, are left out.
  defp build_messages(history, input) do
    earlier =
      for %Turn{status: :ok, input: past_input, output: past_output} <- history,
          is_binary(past_input) and is_binary(past_output),
          do: [
            %{role: :user, content: past_input},
            %{role: :assistant, content: past_output}
          ]

    Enum.concat(Enum.take(earlier, -@maximum_replayed_exchanges)) ++
      [%{role: :user, content: input}]
  end
end
