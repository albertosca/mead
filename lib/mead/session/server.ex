defmodule Mead.Session.Server do
  @moduledoc """
  Orchestrates the turns of one conversation.

  It records each turn in the history before running the handler, runs the handler in a task
  under `Mead.TurnSupervisor`, and replies to the caller once the task reports back.
  """

  use GenServer

  alias Mead.Session
  alias Mead.Session.History
  alias Mead.Session.Turn

  @doc """
  Starts the server for `options[:session_id]`, registered under `Mead.Registry`.

  Required options are `:session_id`, `:handler`, and `:turn_timeout`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    GenServer.start_link(__MODULE__, options, name: Session.via(session_id, :server))
  end

  @impl true
  def init(options) do
    state = %{
      session_id: Keyword.fetch!(options, :session_id),
      handler: Keyword.fetch!(options, :handler),
      turn_timeout: Keyword.fetch!(options, :turn_timeout),
      running: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, input}, from, state) do
    handler = state.handler
    history = History.all(state.session_id)

    History.append(state.session_id, Turn.start(input))

    task =
      Task.Supervisor.async_nolink(Mead.TurnSupervisor, fn ->
        handler.handle_turn(history, input)
      end)

    {:noreply, %{state | running: %{from: from, task: task}}}
  end

  @impl true
  def handle_info({reference, {:ok, output}}, %{running: %{task: %Task{ref: reference}}} = state) do
    Process.demonitor(reference, [:flush])
    History.update_last(state.session_id, &Turn.finish(&1, :ok, output))
    GenServer.reply(state.running.from, {:ok, output})

    {:noreply, %{state | running: nil}}
  end
end
