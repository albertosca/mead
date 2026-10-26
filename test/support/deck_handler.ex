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
end
