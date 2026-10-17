defmodule Mead.Session.History do
  @moduledoc """
  Keeps the turns of one conversation.

  The state is a plain list with the newest turn first. The agent holds no logic beyond list
  manipulation, so it is not expected to crash, and it is started before the session server so
  that a server crash leaves the history untouched.
  """

  use Agent

  alias Mead.Session
  alias Mead.Session.Turn

  @doc "Starts the history for `options[:session_id]`, registered under `Mead.Registry`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    Agent.start_link(fn -> [] end, name: Session.via(session_id, :history))
  end

  @doc "Appends a turn as the newest one."
  @spec append(String.t(), Turn.t()) :: :ok
  def append(session_id, %Turn{} = turn) do
    Agent.update(Session.via(session_id, :history), &[turn | &1])
  end

  @doc "Returns all turns in chronological order."
  @spec all(String.t()) :: [Turn.t()]
  def all(session_id) do
    session_id
    |> Session.via(:history)
    |> Agent.get(&Enum.reverse/1)
  end

  @doc "Replaces the newest turn with the result of `function` applied to it."
  @spec update_last(String.t(), (Turn.t() -> Turn.t())) :: :ok
  def update_last(session_id, function) do
    Agent.update(Session.via(session_id, :history), fn
      [newest | older] -> [function.(newest) | older]
      [] -> []
    end)
  end

  @doc "Marks every turn still in progress as interrupted."
  @spec mark_interrupted(String.t()) :: :ok
  def mark_interrupted(session_id) do
    Agent.update(Session.via(session_id, :history), fn turns ->
      Enum.map(turns, fn
        %Turn{status: :in_progress} = turn -> Turn.finish(turn, :interrupted, turn.output)
        turn -> turn
      end)
    end)
  end
end
