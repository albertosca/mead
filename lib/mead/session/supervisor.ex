defmodule Mead.Session.Supervisor do
  @moduledoc """
  Supervises the two processes of one conversation.

  The history is started before the server and the strategy is `:rest_for_one`, so a server
  crash restarts only the server and leaves the history untouched. The restart intensity is 5
  restarts in 5 seconds: a turn in progress is continued by at most 3 server starts and the 4th
  interrupts it, so a turn that crashes its server every time ends interrupted before the pair
  gives up (the default of 3 would take the pair down first and leave the turn stranded). A
  server that keeps crashing beyond that takes the whole pair down, which is a visible failure
  instead of a hidden loop. A stored conversation survives that and can be brought back with
  `Mead.resume_session/2`; one without storage is gone.
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
      {History,
       Keyword.take(options, [:session_id, :directory, :resume, :compact_after_bytes, :max_turns])},
      {Server, options}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 5)
  end
end
