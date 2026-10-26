defmodule Mead.Deck.Interaction do
  @moduledoc """
  The `Mead.Router.Interaction` of a deck turn: every question and every progress report is a call
  into the `Mead.Deck.Channel` of the session, which owns the policy, the event log and the clock.

  The context is `%{channel: pid, turn_id: String.t()}`. `request_permission/2` returns only when
  the channel has an answer, however long that takes (the channel's own deadline ends the wait),
  so the calls use an infinite timeout. A channel that is gone takes the turn down with it, which
  is right: the session it belongs to is gone too.
  """

  @behaviour Mead.Router.Interaction

  @impl true
  def request_permission(%{channel: channel}, request),
    do: GenServer.call(channel, {:permission_request, request}, :infinity)

  @impl true
  def ask_choice(%{channel: channel}, choice),
    do: GenServer.call(channel, {:choice_request, choice}, :infinity)

  @impl true
  def register_call(%{channel: channel}, tool_call_id, pid),
    do: GenServer.call(channel, {:register_call, tool_call_id, pid}, :infinity)

  @impl true
  def tool_updated(%{channel: channel, turn_id: turn_id}, update),
    do: GenServer.call(channel, {:tool_updated, turn_id, update}, :infinity)
end
