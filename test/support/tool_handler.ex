defmodule Mead.Test.ToolHandler do
  @moduledoc false

  # A turn handler that runs the real `Mead.Router` against scripted providers and a `FakeHub`.
  # The FakeHub keeps its settings in the process that calls it, which for a session is the turn
  # task, so the handler configures it there from `Application.get_env(:mead, :tool_handler)`:
  # `%{slots: slots, hub: settings}`.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(history, input, options) do
    %{slots: slots, hub: hub_settings} = Application.fetch_env!(:mead, :tool_handler)
    Mead.Test.FakeHub.configure(hub_settings)
    Mead.Router.route(history, input, options, slots, Mead.Test.FakeHub)
  end
end
