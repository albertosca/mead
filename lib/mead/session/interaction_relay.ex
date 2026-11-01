defmodule Mead.Session.InteractionRelay do
  @moduledoc """
  The interaction a session hands its turn handler instead of the caller's own, so the turn does
  not hold pids that a restart would leave dead.

  The context is `%{session_id: id}`. Each callback asks `Mead.Session.Server` for the interaction
  attached to the running turn and forwards the call to it, in the turn's own process. A forwarded
  call that exits (the channel behind it died) detaches that interaction and counts as none.

  With nothing attached, `request_permission/2` and `ask_choice/2` wait for one through
  `Mead.Session.Server.await_interaction/2`, at most `config :mead, :recovery,
  interaction_grace:` milliseconds (30 seconds by default) with the turn clock paused. When nothing
  attached in that time, the attempt is unattended and every later question in it is answered at
  once: a permission with `{:deny, :unattended}`, a choice with `{:error, :no_answer}`. The other
  callbacks do nothing without an interaction, and `text_delta/2` reaches only the interaction the
  turn was submitted with, on its first attempt.
  """

  @behaviour Mead.Router.Interaction

  alias Mead.Session.Server

  @default_grace 30_000

  @impl true
  def request_permission(%{session_id: session_id}, request) do
    ask(session_id, {:deny, :unattended}, fn module, context ->
      module.request_permission(context, request)
    end)
  end

  @impl true
  def ask_choice(%{session_id: session_id}, choice) do
    ask(session_id, {:error, :no_answer}, fn module, context ->
      module.ask_choice(context, choice)
    end)
  end

  @impl true
  def tool_updated(%{session_id: session_id}, update) do
    notify(session_id, false, fn module, context -> module.tool_updated(context, update) end)
  end

  @impl true
  def register_call(%{session_id: session_id}, tool_call_id, pid) do
    notify(session_id, false, fn module, context ->
      module.register_call(context, tool_call_id, pid)
    end)
  end

  @impl true
  def text_delta(%{session_id: session_id}, text) do
    notify(session_id, true, fn module, context -> module.text_delta(context, text) end)
  end

  # Every exit detaches the interaction that exited, so the loop ends: at the latest, the wait
  # finds nothing attached and the attempt becomes unattended.
  defp ask(session_id, unattended_answer, call) do
    case Server.await_interaction(session_id, grace()) do
      {:ok, interaction, _streaming} ->
        case forward(session_id, interaction, call) do
          {:ok, answer} -> answer
          :exited -> ask(session_id, unattended_answer, call)
        end

      :none ->
        unattended_answer
    end
  end

  defp notify(session_id, only_streaming, call) do
    case Server.attached_interaction(session_id) do
      {:ok, interaction, streaming} when streaming or not only_streaming ->
        forward(session_id, interaction, call)
        :ok

      _not_attached ->
        :ok
    end
  end

  defp forward(session_id, {module, context} = interaction, call) do
    {:ok, call.(module, context)}
  catch
    :exit, _reason ->
      Server.detach_interaction(session_id, interaction)
      :exited
  end

  defp grace do
    :mead
    |> Application.get_env(:recovery, [])
    |> Keyword.get(:interaction_grace, @default_grace)
  end
end
