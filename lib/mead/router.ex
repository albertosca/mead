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

  The router keeps no state, so every conversation stays independent of the others. Each turn
  emits `[:mead, :router, :route]` with the measurements `duration` (in native time units),
  `input_tokens`, and `output_tokens` (both zero on failure), and the metadata `route`,
  `route_source` (`:classified` or `:forced`), `provider` (the module, or `nil` for an empty
  slot), `status` (`:ok` or `:error`), and `session_id` (the session the server passed in the
  options, `nil` outside a session). A provider that raises instead of returning an error
  emits no event.
  """

  @behaviour Mead.Session.TurnHandler

  alias Mead.Router.Classifier
  alias Mead.Session.Turn

  @event [:mead, :router, :route]
  # A conversation that grows without bound eventually overflows the model's context and then
  # every later turn fails, so only the most recent exchanges are replayed.
  @maximum_replayed_exchanges 20

  @impl true
  def handle_turn(history, input, options) do
    slots =
      :mead
      |> Application.get_env(:router, [])
      |> Keyword.get(:slots, [])

    route(history, input, options, slots)
  end

  @doc """
  Routes one turn through the given `slots`.

  `handle_turn/3` is this function with the slots read from the application environment; it
  exists separately so tests can pass their own slots without touching global state.
  """
  @spec route([Turn.t()], term(), keyword(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def route(history, input, options, slots) do
    started_at = System.monotonic_time()
    {route, route_source} = choose_route(history, input, options)
    slot = if Keyword.keyword?(slots), do: Keyword.get(slots, route), else: :invalid

    {result, provider, usage} = call_slot(slot, route, history, input)

    :telemetry.execute(
      @event,
      %{
        duration: System.monotonic_time() - started_at,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens
      },
      %{
        route: route,
        route_source: route_source,
        provider: provider,
        status: if(match?({:ok, _text}, result), do: :ok, else: :error),
        session_id: Keyword.get(options, :session_id)
      }
    )

    result
  end

  defp choose_route(history, input, options) do
    case Keyword.get(options, :route, :auto) do
      :auto -> {Classifier.classify(history, input), :classified}
      forced -> {forced, :forced}
    end
  end

  defp call_slot(nil, route, _history, _input) do
    {{:error, unavailable_reason(route)}, nil, no_usage()}
  end

  # A slot of any other shape would crash inside the provider with its content in the stacktrace,
  # which the session stores and replies; refuse it by shape instead.
  defp call_slot({provider, provider_options} = slot, _route, history, input) do
    if is_atom(provider) and Keyword.keyword?(provider_options) do
      call_provider(slot, history, input)
    else
      {{:error, :invalid_slot}, nil, no_usage()}
    end
  end

  defp call_slot(_invalid, _route, _history, _input) do
    {{:error, :invalid_slot}, nil, no_usage()}
  end

  defp call_provider({provider, provider_options}, history, input) do
    if is_binary(input) and String.valid?(input) do
      messages = build_messages(history, input)

      case provider.complete(messages, provider_options) do
        {:ok, %{text: text, usage: usage}} -> {{:ok, text}, provider, usage}
        {:error, reason} -> {{:error, reason}, provider, no_usage()}
      end
    else
      {{:error, :unsupported_input}, provider, no_usage()}
    end
  end

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
