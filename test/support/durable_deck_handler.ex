defmodule Mead.Test.DurableDeckHandler do
  @moduledoc false

  # A deck turn handler that can continue. "stream <first>|<final>" records one step, streams
  # `first` through the turn's interaction, tells the test `{:handler_started, pid, input}` (to
  # the processes registered under `{:deck_test_notify, session_id}`) and waits for `:release`,
  # then answers `final`. A continued turn answers `final` at once, without streaming. Anything
  # else answers "reply to: <input>".

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, "stream " <> specification = input, options) do
    [first, final] = String.split(specification, "|", parts: 2)
    :ok = Keyword.fetch!(options, :checkpoint).(:began)
    {module, context} = Keyword.fetch!(options, :interaction)
    module.text_delta(context, first)
    notify(options, {:handler_started, self(), input})

    receive do
      :release -> {:ok, final}
    end
  end

  def handle_turn(_history, input, _options), do: {:ok, "reply to: " <> input}

  @impl true
  def resume_turn(_history, "stream " <> specification, _steps, _options) do
    [_first, final] = String.split(specification, "|", parts: 2)
    {:ok, final}
  end

  def resume_turn(history, input, _steps, options), do: handle_turn(history, input, options)

  defp notify(options, message) do
    session_id = Keyword.fetch!(options, :session_id)

    for {pid, _value} <- Registry.lookup(Mead.Registry, {:deck_test_notify, session_id}) do
      send(pid, message)
    end

    :ok
  end
end
