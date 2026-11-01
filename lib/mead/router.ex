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

  ## Checkpoints

  When the options carry a `:checkpoint` function (the session server adds one to every turn),
  each step is recorded through it as soon as it exists: `{:route, route, route_source}` first,
  then every `{:provider_response, %{content: ..., stop_reason: ..., usage: ...}}` before it is
  acted on, `{:tool_started, tool_use_id, class}` right before a call reaches the hub, and
  `{:tool_result, tool_use_id, result}` for every result the model receives (a denial, an
  `ask_user` answer, and an unknown tool included). A write that fails ends the turn at once with
  `{:error, {:checkpoint_failed, reason}}`, so nothing runs outside the record.

  `resume_turn/4` continues a turn from those steps, by position (some models reuse tool call ids
  across calls): recorded answers and results are used instead of asking again, and replayed
  answers are not streamed again. A call recorded as started with no result is in doubt: a `:read`
  call runs again, and an `:effect` call never does, the model is told it may or may not have
  taken effect. Steps that do not fit are dropped and the turn goes on live from there. Before
  replaying, it waits for the MCP servers to reconnect (`Mead.MCP.Hub.await_ready/2`, at most
  `config :mead, :recovery, hub_wait:` milliseconds, 10 seconds by default). The usage and the
  tool calls of the event cover the replayed steps too, so a continued turn is counted once.

  The same holds for a live `:effect` call whose outcome is unknown: one cancelled while running,
  timed out, cut by a lost connection, or whose process crashed is reported to the model as one
  that may or may not have taken effect, never as a plain failure.
  """

  @behaviour Mead.Session.TurnHandler

  require Logger

  alias Mead.Router.AskUser
  alias Mead.Router.Classifier
  alias Mead.Session.Turn

  @event [:mead, :router, :route]
  # A conversation that grows without bound eventually overflows the model's context and then
  # every later turn fails, so only the most recent exchanges are replayed.
  @maximum_replayed_exchanges 20
  # A model that keeps asking for tools would otherwise spend the turn timeout and the budget.
  @maximum_provider_calls 8
  @text_separator "\n\n"
  # The hub gives up on a tool after 15 seconds; this is the margin for the task around it.
  @tool_wait 20_000
  @default_hub_wait 10_000
  @in_doubt "This call was already running when the server stopped. It may or may not have taken effect; check before calling it again."
  @doubt " It may or may not have taken effect; check before calling it again."

  # Hub errors that come after the request may have reached the tool server: the call went out
  # and no answer came back. Every other hub error means it was never sent.
  @doubtful_errors [:timeout, :connection_lost]

  @impl true
  def handle_turn(history, input, options), do: resume_turn(history, input, [], options)

  @impl true
  def resume_turn(history, input, steps, options) do
    slots =
      :mead
      |> Application.get_env(:router, [])
      |> Keyword.get(:slots, [])

    replay(history, input, steps, options, slots)
  end

  @doc """
  Routes one turn through the given `slots`, with tools from `hub`.

  `handle_turn/3` is this function with the slots read from the application environment and the
  default hub; it exists separately so tests can pass their own slots and hub without touching
  global state. A caller of `Mead.submit_turn/3` cannot choose the hub.
  """
  @spec route([Turn.t()], term(), keyword(), keyword(), module()) ::
          {:ok, String.t()} | {:error, term()}
  def route(history, input, options, slots, hub \\ Mead.MCP.Hub),
    do: replay(history, input, [], options, slots, hub)

  @doc """
  Continues a turn from the `steps` recorded so far, through the given `slots` and `hub`.

  `resume_turn/4` is this function with the slots read from the application environment and the
  default hub, and `route/5` is it with no steps.
  """
  @spec replay([Turn.t()], term(), [term()], keyword(), keyword(), module()) ::
          {:ok, String.t()} | {:error, term()}
  def replay(history, input, steps, options, slots, hub \\ Mead.MCP.Hub) do
    started_at = System.monotonic_time()
    await_hub(steps, hub)
    {recorded_route, segments} = parse_steps(steps)
    {route, route_source} = recorded_route || choose_route(history, input, options)
    slot = if Keyword.keyword?(slots), do: Keyword.get(slots, route), else: :invalid

    outcome =
      try do
        if recorded_route == nil, do: record(options, {:route, route, route_source})
        call_slot(slot, route, history, input, options, hub, segments)
      catch
        {:checkpoint_failed, reason} ->
          outcome({:error, {:checkpoint_failed, reason}}, slot_provider(slot))
      end

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

  defp slot_provider({provider, _provider_options}) when is_atom(provider), do: provider
  defp slot_provider(_slot), do: nil

  # A continued turn must not answer :unknown_tool for calls it already made just because the
  # servers have not reconnected yet. A hub without the function (a test's) is always ready.
  defp await_hub([], _hub), do: :ok

  defp await_hub(_steps, hub) do
    if Code.ensure_loaded?(hub) and function_exported?(hub, :await_ready, 1) do
      wait =
        :mead |> Application.get_env(:recovery, []) |> Keyword.get(:hub_wait, @default_hub_wait)

      hub.await_ready(wait)
    end

    :ok
  end

  # Records a step through the turn's checkpoint, when it has one. A write that fails ends the
  # turn: `replay/6` catches the throw.
  defp record(options, step) do
    case Keyword.get(options, :checkpoint) do
      nil ->
        :ok

      checkpoint ->
        case checkpoint.(step) do
          :ok -> :ok
          {:error, reason} -> throw({:checkpoint_failed, reason})
        end
    end
  end

  # The steps become the recorded route and one segment per recorded provider response, with the
  # tool records that followed it keyed by call id. Ids are unique within one response but not
  # across responses, so the segments are consumed in order. Whatever does not fit ends the parse
  # with a warning: only a bug writes such a log, and the turn goes on live from that point.
  defp parse_steps([{:route, route, source} | rest])
       when route in [:local, :cloud] and source in [:forced, :classified] do
    {segments, dropped} = segments(rest, [])
    warn_dropped(dropped)
    {{route, source}, segments}
  end

  defp parse_steps(steps) do
    warn_dropped(steps)
    {nil, []}
  end

  defp warn_dropped([]), do: :ok

  defp warn_dropped(dropped) do
    count = length(dropped)
    {noun, verb} = if count == 1, do: {"step", "does"}, else: {"steps", "do"}

    Logger.warning(
      "router: dropped #{count} recorded #{noun} that #{verb} not fit; the turn goes on live from there"
    )
  end

  defp segments(
         [
           {:provider_response,
            %{content: content, usage: %{input_tokens: _, output_tokens: _}} = response}
           | rest
         ],
         segments
       )
       when is_list(content) do
    {tool_records, rest} = tool_records(rest, %{})
    segments(rest, [{response, tool_records} | segments])
  end

  defp segments(rest, segments), do: {Enum.reverse(segments), rest}

  defp tool_records([{:tool_started, id, class} | rest], records) when class in [:read, :effect],
    do: tool_records(rest, put_record(records, id, :started, class))

  defp tool_records([{:tool_result, id, %{type: :tool_result} = result} | rest], records),
    do: tool_records(rest, put_record(records, id, :result, result))

  defp tool_records(rest, records), do: {records, rest}

  defp put_record(records, id, key, value),
    do: Map.update(records, id, %{key => value}, &Map.put(&1, key, value))

  defp choose_route(history, input, options) do
    case Keyword.get(options, :route, :auto) do
      :auto -> {Classifier.classify(history, input), :classified}
      forced -> {forced, :forced}
    end
  end

  defp outcome(result, provider, usage \\ no_usage(), tool_calls \\ 0) do
    %{result: result, provider: provider, usage: usage, tool_calls: tool_calls}
  end

  defp call_slot(nil, route, _history, _input, _options, _hub, _segments) do
    outcome({:error, unavailable_reason(route)}, nil)
  end

  # A slot of any other shape would crash inside the provider with its content in the stacktrace,
  # which the session stores and replies; refuse it by shape instead.
  defp call_slot(
         {provider, provider_options} = slot,
         _route,
         history,
         input,
         options,
         hub,
         segments
       ) do
    if is_atom(provider) and Keyword.keyword?(provider_options) do
      call_provider(slot, history, input, options, hub, segments)
    else
      outcome({:error, :invalid_slot}, nil)
    end
  end

  defp call_slot(_invalid, _route, _history, _input, _options, _hub, _segments) do
    outcome({:error, :invalid_slot}, nil)
  end

  defp call_provider({provider, provider_options}, history, input, options, hub, segments) do
    if is_binary(input) and String.valid?(input) do
      messages = build_messages(history, input)

      case tools_for_turn(provider, options, hub) do
        [] ->
          complete_once(provider, provider_options, messages, options, segments)

        tools ->
          converse_loop(provider, provider_options, messages, tools, options, hub, segments)
      end
    else
      outcome({:error, :unsupported_input}, provider)
    end
  end

  # A recorded text answer is the answer; anything else recorded (a turn that asked for tools that
  # are no longer visible) is not, and the answer is asked for again.
  defp complete_once(provider, provider_options, messages, options, segments) do
    case recorded_text(segments) do
      {:ok, text, usage} -> outcome({:ok, text}, provider, usage)
      :none -> complete_live(provider, provider_options, messages, options)
    end
  end

  defp recorded_text([
         {%{content: content, stop_reason: stop_reason, usage: usage}, _records} | _rest
       ])
       when stop_reason != :tool_use do
    case for(%{type: :text, text: text} <- content, do: text) do
      [] -> :none
      texts -> {:ok, Enum.join(texts), usage}
    end
  end

  defp recorded_text(_segments), do: :none

  defp complete_live(provider, provider_options, messages, options) do
    case streaming_callback(provider, options) do
      nil -> complete_plain(provider, provider_options, messages, options)
      on_delta -> complete_streamed(provider, provider_options, messages, options, on_delta)
    end
  end

  defp complete_plain(provider, provider_options, messages, options) do
    case provider.complete(messages, provider_options) do
      {:ok, %{text: text, usage: usage}} ->
        record_response(options, [%{type: :text, text: text}], :end_turn, usage)
        outcome({:ok, text}, provider, usage)

      {:error, reason} ->
        outcome({:error, reason}, provider)
    end
  end

  # A streaming provider answers a tool-less turn through `converse_stream/4` with no tools, which
  # gives the same text and usage `complete/2` would.
  defp complete_streamed(provider, provider_options, messages, options, on_delta) do
    case provider.converse_stream(messages, [], provider_options, on_delta) do
      {:ok, %{content: content, usage: usage} = response} ->
        case for(%{type: :text, text: text} <- content, do: text) do
          [] ->
            outcome({:error, :malformed_response}, provider)

          texts ->
            record_response(options, content, Map.get(response, :stop_reason, :end_turn), usage)
            outcome({:ok, Enum.join(texts)}, provider, usage)
        end

      {:error, reason} ->
        outcome({:error, reason}, provider)
    end
  end

  defp record_response(options, content, stop_reason, usage) do
    record(
      options,
      {:provider_response, %{content: content, stop_reason: stop_reason, usage: usage}}
    )
  end

  # Streaming needs somebody to show the fragments to (an interaction) and a provider that can.
  defp streaming_callback(provider, options) do
    with {module, interaction_context} <- Keyword.get(options, :interaction),
         true <-
           Code.ensure_loaded?(provider) and function_exported?(provider, :converse_stream, 4) do
      fn text -> module.text_delta(interaction_context, text) end
    else
      _not_streaming -> nil
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

  defp converse_loop(provider, provider_options, messages, tools, options, hub, segments) do
    context = %{
      provider: provider,
      provider_options: provider_options,
      tools: tools,
      options: options,
      hub: hub,
      on_delta: streaming_callback(provider, options),
      record_start: true
    }

    {result, progress} =
      loop(context, messages, %{calls: 0, tool_calls: 0, usage: no_usage(), texts: []}, segments)

    outcome(result, provider, progress.usage, progress.tool_calls)
  end

  defp converse(%{on_delta: nil} = context, messages, _progress),
    do: context.provider.converse(messages, context.tools, context.provider_options)

  defp converse(context, messages, progress) do
    context.provider.converse_stream(
      messages,
      context.tools,
      context.provider_options,
      separated(context.on_delta, progress.texts != [])
    )
  end

  # The first fragment of a call that follows spoken text carries the separator the stored output
  # has between calls, so the streamed deltas join to exactly what the turn returns.
  defp separated(on_delta, false), do: on_delta

  defp separated(on_delta, true) do
    first = :atomics.new(1, [])

    fn fragment ->
      if :atomics.add_get(first, 1, 1) == 1 and fragment != "",
        do: on_delta.(@text_separator <> fragment),
        else: on_delta.(fragment)
    end
  end

  # The next answer is the next recorded one, with the tool records that followed it, or a fresh
  # one, recorded before it is acted on. A replayed answer is not streamed again.
  defp next_response(_context, _messages, _progress, [{response, records} | rest]),
    do: {{:ok, response}, records, rest}

  defp next_response(context, messages, progress, []) do
    case converse(context, messages, progress) do
      {:ok, %{content: content, usage: usage} = response} = answer ->
        record_response(context.options, content, Map.get(response, :stop_reason), usage)
        {answer, %{}, []}

      other ->
        {other, %{}, []}
    end
  end

  defp loop(context, messages, progress, segments) do
    {answer, records, segments} = next_response(context, messages, progress, segments)

    case answer do
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
            results = Enum.map(tool_uses, &tool_result(context, &1, records))
            said = for %{type: :text, text: text} <- content, text != "", do: text

            messages =
              messages ++
                [%{role: :assistant, content: content}, %{role: :user, content: results}]

            # The next call's text follows what was already said; the stream gets the same
            # separator the stored output has, so a replay matches the live view.
            progress = %{
              progress
              | tool_calls: progress.tool_calls + length(tool_uses),
                texts: progress.texts ++ said
            }

            loop(context, messages, progress, segments)
        end

      {:ok, %{content: content, usage: usage}} ->
        progress = add_call(progress, usage)

        case for(%{type: :text, text: text} <- content, do: text) do
          [] ->
            {{:error, :malformed_response}, progress}

          texts ->
            {{:ok, Enum.join(progress.texts ++ [Enum.join(texts)], @text_separator)}, progress}
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

  # A recorded result is used as is. A call recorded as started with no result is in doubt: an
  # effect never runs again and the model is told so; a read runs again, without being recorded as
  # started a second time. Every result the model gets is recorded.
  defp tool_result(context, tool_use, records) do
    case Map.get(records, tool_use.id, %{}) do
      %{result: result} ->
        result

      %{started: :effect} ->
        recorded_result(context, error_result(tool_use, @in_doubt))

      %{started: :read} ->
        recorded_result(context, run_tool_for_turn(%{context | record_start: false}, tool_use))

      _not_started ->
        recorded_result(context, run_tool_for_turn(context, tool_use))
    end
  end

  defp recorded_result(context, result) do
    record(context.options, {:tool_result, result.tool_use_id, result})
    result
  end

  # Recorded right before the hub is called. Without an interaction the class is asked for only
  # when there is a checkpoint to record it in; a name the hub does not know counts as an effect,
  # the safe side, and the hub refuses it anyway.
  defp record_start(%{record_start: false}, _tool_use, _class), do: :ok

  defp record_start(context, tool_use, class) do
    if Keyword.has_key?(context.options, :checkpoint) do
      record(context.options, {:tool_started, tool_use.id, class.()})
    end

    :ok
  end

  defp class_of(context, tool_use) do
    case context.hub.describe_tool(tool_use.name, context.options) do
      {:ok, %{class: class}} -> class
      {:error, _reason} -> :effect
    end
  end

  # `class` is asked for only when the outcome is in doubt: an effect call that may have run is
  # reported so, and the model checks before calling it again.
  defp run_tool(context, %{id: id, name: name, input: input} = tool_use, class) do
    case context.hub.call_tool(name, input, context.options) do
      {:ok, %{content: content, is_error: is_error}} ->
        %{type: :tool_result, tool_use_id: id, content: content, is_error: is_error}

      {:error, reason} when reason in @doubtful_errors ->
        doubtful_result(tool_use, "The tool call failed: #{describe(reason)}.", class)

      {:error, reason} ->
        error_result(tool_use, "The tool call failed: #{describe(reason)}.")
    end
  end

  defp doubtful_result(tool_use, text, class) do
    if class.() == :effect,
      do: error_result(tool_use, text <> @doubt),
      else: error_result(tool_use, text)
  end

  # Without an interaction the old path runs untouched; with one, every call is announced, asked
  # about, and reported, and a denied call never reaches the hub.
  defp run_tool_for_turn(context, tool_use) do
    case Keyword.get(context.options, :interaction) do
      nil ->
        class = fn -> class_of(context, tool_use) end
        record_start(context, tool_use, class)
        run_tool(context, tool_use, class)

      interaction ->
        if tool_use.name == AskUser.name(),
          do: run_ask_user(interaction, tool_use),
          else: run_tool_with_interaction(context, interaction, tool_use)
    end
  end

  defp run_ask_user({module, interaction_context}, %{id: id, input: input} = tool_use) do
    with {:ok, question} <- AskUser.validate(input),
         choice = %{
           tool_call_id: id,
           prompt: question.prompt,
           options: question.options,
           allow_free_text: question.allow_free_text
         },
         {:ok, answer} <- module.ask_choice(interaction_context, choice),
         {:ok, content} <- describe_answer(question, answer) do
      %{type: :tool_result, tool_use_id: id, content: content, is_error: false}
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

  # A typed answer counts only for a question that allowed it, so an interaction cannot hand the
  # model words the person was never invited to give.
  defp describe_answer(%{allow_free_text: true}, {:text, text}),
    do: {:ok, "The person answered: #{text}"}

  defp describe_answer(question, option_id) when is_binary(option_id) do
    case Enum.find(question.options, &(&1.id == option_id)) do
      %{label: label} -> {:ok, "The person chose: #{label}"}
      nil -> :unknown_option
    end
  end

  defp describe_answer(_question, _answer), do: :unknown_option

  defp run_tool_with_interaction(context, {module, interaction_context}, tool_use) do
    update = fn status, overrides ->
      module.tool_updated(interaction_context, tool_update(tool_use, status, overrides))
    end

    update.(:pending, %{})

    with {:ok, target} <- context.hub.describe_tool(tool_use.name, context.options),
         :allow <-
           module.request_permission(interaction_context, permission_request(tool_use, target)) do
      record_start(context, tool_use, fn -> target.class end)

      class = fn -> target.class end

      case run_cancellable(context, module, interaction_context, tool_use, class) do
        {:finished, result} ->
          update.(if(result.is_error, do: :failed, else: :completed), %{})
          result

        :cancelled ->
          update.(:failed, %{current_step: "cancelled"})
          doubtful_result(tool_use, "The person cancelled this tool call.", class)
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
  # A tool process that crashed, was cancelled or ran out of time was stopped while the call was
  # out, so an effect call is reported as one that may have run.
  defp run_cancellable(context, module, interaction_context, tool_use, class) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(Mead.TurnSupervisor, fn ->
        watch_owner(owner)
        run_tool(context, tool_use, class)
      end)

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
        {:finished,
         doubtful_result(tool_use, "The tool call failed: #{describe(reason)}.", class)}

      nil ->
        {:finished,
         doubtful_result(tool_use, "The tool call failed: #{describe(:timeout)}.", class)}
    end
  end

  # The task is not linked to the router, so a router that dies (its turn timed out, or it was
  # killed) would leave the tool running with nobody to wait for it. The watcher ends the tool
  # when the router goes, and ends itself when the tool does.
  defp watch_owner(owner) do
    tool = self()

    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      tool_monitor = Process.monitor(tool)

      receive do
        {:DOWN, ^owner_monitor, :process, _pid, _reason} -> Process.exit(tool, :kill)
        {:DOWN, ^tool_monitor, :process, _pid, _reason} -> :ok
      end
    end)
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

  defp denial_text(:unattended),
    do: "Nobody was there to approve this call after the server restarted, so it was not run."

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
