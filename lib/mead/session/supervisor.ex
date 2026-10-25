defmodule Mead.Session.Supervisor do
  @moduledoc """
  Supervises the two processes of one conversation.

  The history is started before the server and the strategy is `:rest_for_one`, so a server
  crash restarts only the server and leaves the history untouched. The default restart
  intensity applies: a server that crashes more than 3 times in 5 seconds takes the whole pair
  down, and the conversation is gone, which is a visible failure instead of a hidden loop.
  """

  use Supervisor, restart: :transient

  alias Mead.Session
  alias Mead.Session.History
  alias Mead.Session.Server

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    Supervisor.start_link(__MODULE__, options, name: Session.via(session_id, :supervisor))
  end

  @impl true
  def init(options) do
    children = [
      {History, Keyword.take(options, [:session_id, :directory, :resume])},
      {Server, options}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
