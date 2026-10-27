defmodule Mead.Test.DeckHandler do
  @moduledoc false

  # A turn handler for the deck tests, chosen by the prompt text. A test that wants to know when a
  # turn starts registers itself under `{:deck_test_notify, session_id}` in `Mead.Registry`; the
  # key carries the session id so tests that run side by side never hear each other.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, "echo " <> text, _options), do: {:ok, text}
  def handle_turn(_history, "error", _options), do: {:error, :boom}
  def handle_turn(_history, "binary", _options), do: {:ok, <<255, 254>>}
  def handle_turn(_history, "empty", _options), do: {:ok, ""}

  def handle_turn(_history, "block" <> _label = input, options) do
    notify(options, {:handler_started, self(), input})

    receive do
      :release -> {:ok, "released " <> input}
    end
  end

  # "ask <read|effect> <server>__<tool> <argument text>" plays the router's calls on the turn's
  # interaction for one tool call and answers "allowed" or "denied <reason>".
  def handle_turn(_history, "ask " <> specification, options) do
    [class, name, argument_text] = String.split(specification, " ", parts: 3)
    [server, tool] = String.split(name, "__", parts: 2)
    {module, context} = Keyword.fetch!(options, :interaction)

    request = %{
      tool_call_id: "call-1",
      tool: tool,
      server: server,
      class: String.to_existing_atom(class),
      arguments: %{"argument" => argument_text}
    }

    update = fn status ->
      module.tool_updated(context, %{
        tool_call_id: "call-1",
        title: name,
        status: status,
        current_step: nil,
        progress: nil,
        cancellable: false
      })
    end

    update.(:pending)

    case module.request_permission(context, request) do
      :allow ->
        update.(:in_progress)
        update.(:completed)
        {:ok, "allowed"}

      {:deny, reason} ->
        update.(:failed)
        {:ok, "denied #{reason}"}
    end
  end

  # "choose <id>,<id>,..." puts a question with those options (labelled "Label <id>") and answers
  # "chose <id>" or "no choice <reason>".
  def handle_turn(_history, "choose " <> identifiers, options),
    do: ask_choice(identifiers, false, options)

  # Same as "choose", but the person may also answer in their own words ("typed <text>").
  def handle_turn(_history, "choosefree " <> identifiers, options),
    do: ask_choice(identifiers, true, options)

  def handle_turn(_history, "telemetry " <> numbers, options) do
    [input_tokens, output_tokens] = numbers |> String.split(" ") |> Enum.map(&String.to_integer/1)

    :telemetry.execute(
      [:mead, :router, :route],
      %{duration: 1, input_tokens: input_tokens, output_tokens: output_tokens, tool_calls: 0},
      %{
        route: :local,
        route_source: :explicit,
        provider: :test,
        status: :ok,
        session_id: Keyword.get(options, :session_id)
      }
    )

    {:ok, "counted"}
  end

  def handle_turn(_history, input, _options), do: {:ok, "reply to: " <> input}

  defp notify(options, message) do
    session_id = Keyword.fetch!(options, :session_id)

    for {pid, _value} <- Registry.lookup(Mead.Registry, {:deck_test_notify, session_id}) do
      send(pid, message)
    end

    :ok
  end

  defp ask_choice(identifiers, allow_free_text, options) do
    {module, context} = Keyword.fetch!(options, :interaction)
    option_ids = String.split(identifiers, ",")

    choice = %{
      tool_call_id: "ask-1",
      prompt: "Which one?",
      options: Enum.map(option_ids, &%{id: &1, label: "Label " <> &1}),
      allow_free_text: allow_free_text
    }

    case module.ask_choice(context, choice) do
      {:ok, {:text, text}} -> {:ok, "typed " <> text}
      {:ok, option_id} -> {:ok, "chose " <> option_id}
      {:error, reason} -> {:ok, "no choice #{reason}"}
    end
  end
end
