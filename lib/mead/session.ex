defmodule Mead.Session do
  @moduledoc """
  Registry helpers shared by the processes that make up one conversation.

  Every conversation owns three registered processes, its `:supervisor`, a `:history` keeper,
  and a `:server`, all found under `Mead.Registry` by `{role, session_id}`.
  """

  @type role :: :supervisor | :history | :server

  @roles [:supervisor, :history, :server]

  @doc "Returns the `:via` name under which a conversation's process registers itself."
  @spec via(String.t(), role()) :: {:via, Registry, {atom(), {role(), String.t()}}}
  def via(session_id, role) when role in @roles do
    {:via, Registry, {Mead.Registry, {role, session_id}}}
  end

  @doc "Returns the pid registered for a conversation's role, or `nil` when there is none."
  @spec whereis(String.t(), role()) :: pid() | nil
  def whereis(session_id, role) when role in @roles do
    case Registry.lookup(Mead.Registry, {role, session_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
