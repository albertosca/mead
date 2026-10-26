defmodule Mead.Router do
  @moduledoc """
  Turn handler that sends each turn to a local or a cloud model.

  The route is the one forced with `Mead.submit_turn/3` (`route: :local` or `route: :cloud`) or,
  for `route: :auto`, the one `Mead.Router.Classifier` picks. The route names a slot, and each
  slot holds a `{provider_module, provider_options}` pair implementing `Mead.Provider`, read from
  the application environment:

      config :mead, :router,
        slots: [
          local: {Mead.Provider.Ollama, model: "llama3.1"},
          cloud: {Mead.Provider.Anthropic, model: "claude-sonnet-5-5"}
        ]

  A turn routed to an empty slot fails with `:local_unavailable` or `:cloud_unavailable` and
  nothing is sent anywhere. In particular a turn meant for the local model is never sent to the
  cloud on its own.

  ## Tools

  When the provider of the chosen slot exports `converse/3`, whichever the route, and `Mead.MCP.Hub.tools_for/1` shows at least one tool for the turn, the turn becomes a loop: the model answers or asks for tools, each requested call goes to `Mead.MCP.Hub.call_tool/3`, and the results are sent back, until the model answers with text. The loop stops after eight provider calls with `:tool_loop_limit`. A tool that fails, is not allowed, or does not exist is reported to the model as an error result and is never retried; the turn does not fail for it. The turn option `tools: :effect` also shows tools that have side effects; see `Mead.MCP.Policy`. The whole loop runs inside the turn timeout, so a conversation that uses tools may need a larger `:turn_timeout` than the default of 30 seconds.

  A tool result goes back to the model of the route that asked for it. A local turn therefore reaches every MCP server the cloud route reaches, including servers that talk to the network, and the result is seen only by the local model. A local model that does not support tools fails the turn with `:tools_unsupported` as soon as any tool is visible; the way out is `route: :cloud`, another model, or no tools configured.

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

  alias Mead.Router.AskUser
  alias Mead.Router.Classifier
  alias Mead.Session.Turn

  @event [:mead, :router, :route]
  # A conversation that grows without bound eventually overflows the model's context and then
  # every later turn fails, so only the most recent exchanges are replayed.
  @maximum_replayed_exchanges 20
  # A model that keeps asking for tools would otherwise spend the turn timeout and the budget.
  @maximum_provider_calls 8
  # The hub gives up on a tool after 15 seconds; this is the margin for the task around it.
  @tool_wait 20_000

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
  defp call_slot({provider, provider_options} = slot, _route, history, input, options, hub) do
    if is_atom(provider) and Keyword.keyword?(provider_options) do
      call_provider(slot, history, input, options, hub)
    else
      outcome({:error, :invalid_slot}, nil)
    end
  end

  defp call_slot(_invalid, _route, _history, _input, _options, _hub) do
    outcome({:error, :invalid_slot}, nil)
  end

  defp call_provider({provider, provider_options}, history, input, options, hub) do
    if is_binary(input) and String.valid?(input) do
      messages = build_messages(history, input)

      case tools_for_turn(provider, options, hub) do
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

  # Tools are offered on either route, and only through a provider that can carry them.
  defp tools_for_turn(provider, options, hub) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :converse, 3) do
      add_ask_user(hub.tools_for(options), options)
    else
      []
    end
  end

  # `ask_user` rides along only when the turn already has tools: a turn with none stays a plain
  # completion, so a model without tool support is not turned away just for the built-in.
  defp add_ask_user([], _options), do: []

  defp add_ask_user(tools, options) do
    if Keyword.has_key?(options, :interaction), do: tools ++ [AskUser.tool()], else: tools
  end

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

  defp loop(context, messages, progress) do
    case context.provider.converse(messages, context.tools, context.provider_options) do
      {:ok, %{content: content, stop_reason: :tool_use, usage: usage}} ->
        progress = add_call(progress, usage)

        case for(%{type: :tool_use} = block <- content, do: block) do
          [] ->
            {{:error, :malformed_response}, progress}

          _tool_uses when progress.calls >= @maximum_provider_calls ->
            # The model would never see the results of these calls, and a tool with side effects
            # would have run for nothing.
            {{:error, :tool_loop_limit}, progress}

          tool_uses ->
            results = Enum.map(tool_uses, &run_tool_for_turn(context, &1))

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

  # Without an interaction the old path runs untouched; with one, every call is announced, asked
  # about, and reported, and a denied call never reaches the hub.
  defp run_tool_for_turn(context, tool_use) do
    case Keyword.get(context.options, :interaction) do
      nil ->
        run_tool(context, tool_use)

      interaction ->
        if tool_use.name == AskUser.name(),
          do: run_ask_user(interaction, tool_use),
          else: run_tool_with_interaction(context, interaction, tool_use)
    end
  end

  defp run_ask_user({module, interaction_context}, %{id: id, input: input} = tool_use) do
    with {:ok, question} <- AskUser.validate(input),
         choice = %{tool_call_id: id, prompt: question.prompt, options: question.options},
         {:ok, option_id} <- module.ask_choice(interaction_context, choice),
         %{label: label} <- Enum.find(question.options, &(&1.id == option_id)) do
      %{
        type: :tool_result,
        tool_use_id: id,
        content: "The person chose: #{label}",
        is_error: false
      }
    else
      {:error, :expired} ->
        error_result(tool_use, "The person did not choose in time.")

      {:error, :no_answer} ->
        error_result(tool_use, "The person could not be asked.")

      {:error, reason} when is_binary(reason) ->
        error_result(tool_use, "The ask_user arguments are invalid: #{reason}.")

      _unknown_option ->
        error_result(tool_use, "The person could not be asked.")
    end
  end

  defp run_tool_with_interaction(context, {module, interaction_context}, tool_use) do
    update = fn status, overrides ->
      module.tool_updated(interaction_context, tool_update(tool_use, status, overrides))
    end

    update.(:pending, %{})

    with {:ok, target} <- context.hub.describe_tool(tool_use.name, context.options),
         :allow <-
           module.request_permission(interaction_context, permission_request(tool_use, target)) do
      case run_cancellable(context, module, interaction_context, tool_use) do
        {:finished, result} ->
          update.(if(result.is_error, do: :failed, else: :completed), %{})
          result

        :cancelled ->
          update.(:failed, %{current_step: "cancelled"})
          error_result(tool_use, "The person cancelled this tool call.")
      end
    else
      {:deny, reason} ->
        update.(:failed, %{})
        error_result(tool_use, denial_text(reason))

      {:error, reason} ->
        update.(:failed, %{})
        error_result(tool_use, "The tool call failed: #{describe(reason)}.")
    end
  end

  # The tool runs in its own process so that whoever holds the pid (registered with the
  # interaction) can cancel it by killing it. Only that kill reads as a cancellation.
  defp run_cancellable(context, module, interaction_context, tool_use) do
    task =
      Task.Supervisor.async_nolink(Mead.TurnSupervisor, fn -> run_tool(context, tool_use) end)

    module.register_call(interaction_context, tool_use.id, task.pid)

    module.tool_updated(
      interaction_context,
      tool_update(tool_use, :in_progress, %{cancellable: true})
    )

    case Task.yield(task, @tool_wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:finished, result}

      {:exit, :killed} ->
        :cancelled

      {:exit, reason} ->
        {:finished, error_result(tool_use, "The tool call failed: #{describe(reason)}.")}

      nil ->
        {:finished, error_result(tool_use, "The tool call failed: #{describe(:timeout)}.")}
    end
  end

  defp tool_update(%{id: id, name: name}, status, overrides) do
    Map.merge(
      %{
        tool_call_id: id,
        title: name,
        status: status,
        current_step: nil,
        progress: nil,
        cancellable: false
      },
      overrides
    )
  end

  defp permission_request(%{id: id, input: input}, target) do
    %{
      tool_call_id: id,
      tool: target.tool,
      server: Atom.to_string(target.server),
      class: target.class,
      arguments: input
    }
  end

  defp error_result(%{id: id}, content) do
    %{type: :tool_result, tool_use_id: id, content: content, is_error: true}
  end

  defp denial_text(:rejected), do: "The person rejected this tool call."

  defp denial_text(:expired),
    do: "The person did not answer in time, so this tool call was not run."

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
