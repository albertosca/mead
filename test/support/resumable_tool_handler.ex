defmodule Mead.Test.ResumableToolHandler do
  @moduledoc false

  # `Mead.Test.ToolHandler` with `resume_turn/4`: the real `Mead.Router`, scripted providers and a
  # `FakeHub` configured from `Application.get_env(:mead, :tool_handler)`, continued from the
  # recorded steps after a restart.

  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(history, input, options), do: resume_turn(history, input, [], options)

  @impl true
  def resume_turn(history, input, steps, options) do
    %{slots: slots, hub: hub_settings} = Application.fetch_env!(:mead, :tool_handler)
    Mead.Test.FakeHub.configure(hub_settings)
    Mead.Router.replay(history, input, steps, options, slots, Mead.Test.FakeHub)
  end
end
