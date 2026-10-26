defmodule Mead do
  @moduledoc """
  Public API of the `mead` runtime: isolated, supervised conversation sessions.

  Each session keeps its history across crashes of its server process. The code that produces
  the output of a turn is a `Mead.Session.TurnHandler`, chosen per session.

  With `config :mead, :storage, directory: ...` the turns of every session are also written to
  disk, and `resume_session/2` brings a stopped session back with the same id and turns. A stored
  file is compacted at resume, when a live one grows past `compact_after_bytes`, and on request
  with `compact_session/1`.
  """

  require Logger

  alias Mead.Session
  alias Mead.Session.EchoHandler
  alias Mead.Session.History
  alias Mead.Session.Pool
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @default_turn_timeout 30_000
  @routes [:auto, :local, :cloud]
  # The longest delay `Process.send_after/3` accepts on every platform.
  @maximum_turn_timeout 4_294_967_295
  @default_recent 20
  @maximum_recent 100

  @doc """
  Starts a session and returns its id.

  ## Options

    * `:handler` - module implementing `Mead.Session.TurnHandler`; defaults to the
      `:turn_handler` application setting, then to `Mead.Session.EchoHandler`.
    * `:turn_timeout` - milliseconds a single turn may run; defaults to the `:turn_timeout`
      application setting, then to 30 seconds.

  Raises `ArgumentError` when `config :mead, :storage` is malformed, rather than quietly running
  without the persistence the operator asked for.
  """
  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(options \\ []) do
    options = validate_options!(options)
    launch(Mead.UUID.generate(), options, [])
  end

  @doc """
  Starts a session again from the conversation stored under `session_id`.

  It takes the options of `start_session/1`, because the handler and the timeout are not stored.
  Turns that were still running when the session ended come back as `:interrupted`. Needs
  `config :mead, :storage, directory: ...`; without it nothing is stored and the answer is
  `{:error, :not_found}`, which is also the answer for an id with no file or one that is not a
  session id. A running session is `{:error, :already_running}`, and a file damaged anywhere but
  its last record is `{:error, :corrupt_history}`. The file is compacted first; a failed
  compaction only logs a warning.
  """
  @spec resume_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_session(session_id, options \\ []) do
    options = validate_options!(options)

    case Store.directory() do
      nil -> {:error, :not_found}
      directory -> resume_from(directory, session_id, options)
    end
  end

  defp resume_from(directory, session_id, options) do
    exclusive(session_id, fn ->
      if Session.whereis(session_id, :supervisor) do
        {:error, :already_running}
      else
        with {:ok, recovered} <- Store.recover(directory, session_id) do
          # Interrupted before compacting, so the file is already what the history would write.
          turns = Enum.map(recovered, &Turn.interrupt/1)
          compact_quietly(directory, session_id, turns)
          launch(session_id, options, resume: turns)
        end
      end
    end)
  end

  # Resuming and deleting the same conversation must not interleave: a resume that loaded the file
  # just before a delete removed it would leave a running session with no file behind it.
  defp exclusive(session_id, function) do
    :global.trans({{__MODULE__, session_id}, self()}, function)
  end

  # Housekeeping must not stop a conversation from coming back, so a failed rewrite only warns.
  defp compact_quietly(directory, session_id, turns) do
    case Store.compact(directory, session_id, turns) do
      {:ok, _sizes} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not compact the history of session #{session_id}: #{inspect(reason)}"
        )
    end
  end

  defp launch(session_id, options, extra) do
    session_options =
      [
        session_id: session_id,
        handler:
          options
          |> Keyword.get_lazy(:handler, fn ->
            Application.get_env(:mead, :turn_handler, EchoHandler)
          end)
          |> validate_handler!(),
        turn_timeout:
          options
          |> Keyword.get_lazy(:turn_timeout, fn ->
            Application.get_env(:mead, :turn_timeout, @default_turn_timeout)
          end)
          |> validate_turn_timeout!(),
        directory: Store.directory(),
        compact_after_bytes: Store.compact_after_bytes()
      ] ++ extra

    case Pool.start_session(session_options) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _pid}} -> {:error, :already_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_options!(options) do
    if Keyword.keyword?(options) do
      Keyword.validate!(options, [:handler, :turn_timeout])
    else
      raise ArgumentError, "options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false] do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :handle_turn, 3) do
      handler
    else
      raise ArgumentError,
            "handler #{inspect(handler)} must be a module that defines handle_turn/3"
    end
  end

  defp validate_handler!(handler) do
    raise ArgumentError,
          "handler #{inspect(handler)} must be a module that defines handle_turn/3"
  end

  defp validate_turn_timeout!(turn_timeout)
       when is_integer(turn_timeout) and turn_timeout > 0 and
              turn_timeout <= @maximum_turn_timeout do
    turn_timeout
  end

  defp validate_turn_timeout!(turn_timeout) do
    raise ArgumentError,
          "turn_timeout must be a positive integer of at most #{@maximum_turn_timeout} milliseconds, " <>
            "got: #{inspect(turn_timeout)}"
  end

  @doc """
  Runs one turn and returns its output.

  ## Options

    * `:route` - `:auto` (the default), `:local`, or `:cloud`; read by `Mead.Router` and ignored
      by other handlers. Any other value returns `{:error, :invalid_route}` before a turn is
      recorded.
    * `:tools` - `:effect` also shows the model tools that have side effects; see
      `Mead.MCP.Policy`. Handed to the handler unchanged and absent when not given.

  Returns `{:error, :not_found}` for an unknown session, `{:error, :session_stopped}` when the
  session was stopped with `stop_session/1` while the turn was running, and
  `{:error, :session_crashed}` when the session's server died for any other reason.
  """
  @spec submit_turn(String.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def submit_turn(session_id, input, options \\ []) do
    options = validate_submit_options!(options)

    if Keyword.fetch!(options, :route) in @routes do
      run_turn(session_id, input, options)
    else
      {:error, :invalid_route}
    end
  end

  defp validate_submit_options!(options) do
    if Keyword.keyword?(options) do
      Keyword.validate!(options, [:tools, route: :auto])
    else
      raise ArgumentError, "options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp run_turn(session_id, input, options) do
    case Session.whereis(session_id, :server) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, {:submit, input, options}, :infinity)
        catch
          :exit, {{:shutdown, _detail}, _call} -> {:error, :session_stopped}
          :exit, {:shutdown, _call} -> {:error, :session_stopped}
          :exit, _reason -> {:error, :session_crashed}
        end
    end
  end

  @doc "Returns the turns of a session in chronological order."
  @spec history(String.t()) :: {:ok, [Turn.t()]} | {:error, :not_found}
  def history(session_id) do
    case Session.whereis(session_id, :history) do
      nil -> {:error, :not_found}
      _pid -> {:ok, History.all(session_id)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @doc """
  Lists the stored conversations, newest first.

  Each entry has the `:session_id`, the `:updated_at` of its file, and whether the session
  `:running` now. Only file times are read, so a damaged conversation is listed too and fails at
  `resume_session/2`. Without `config :mead, :storage, directory: ...` nothing is stored and the
  list is empty.
  """
  @spec list_sessions() ::
          {:ok, [%{session_id: String.t(), updated_at: DateTime.t(), running: boolean()}]}
          | {:error, {:persistence, term()}}
  def list_sessions do
    case Store.directory() do
      nil ->
        {:ok, []}

      directory ->
        with {:ok, entries} <- Store.list(directory) do
          {:ok,
           Enum.map(entries, fn entry ->
             Map.put(entry, :running, Session.whereis(entry.session_id, :supervisor) != nil)
           end)}
        end
    end
  end

  @doc """
  Rewrites the stored conversation as one record per turn and returns the bytes before and after.

  Nothing is lost: `history/1` and `resume_session/2` see the same turns. A running session is
  compacted from memory, a stopped one from its file. Returns `{:error, :not_found}` without
  storage, for an id that is not a session id, and when no file exists yet,
  `{:error, :corrupt_history}` for a damaged file, which is left as it is, and
  `{:error, {:persistence, reason}}` when the rewrite failed and the file is untouched.
  """
  @spec compact_session(String.t()) ::
          {:ok, %{bytes_before: non_neg_integer(), bytes_after: non_neg_integer()}}
          | {:error, :not_found | :corrupt_history | {:persistence, term()}}
  def compact_session(session_id) do
    case Store.directory() do
      nil -> {:error, :not_found}
      directory -> exclusive(session_id, fn -> compact_stored(directory, session_id) end)
    end
  end

  defp compact_stored(directory, session_id) do
    if Session.whereis(session_id, :history) do
      try do
        History.compact(session_id)
      catch
        :exit, _reason -> {:error, :not_found}
      end
    else
      with {:ok, turns} <- Store.recover(directory, session_id) do
        Store.compact(directory, session_id, turns)
      end
    end
  end

  @doc """
  Stops a session. Its ledger aggregate stays, so a conversation brought back with
  `resume_session/2` returns with what it already spent.

  The conversation stays on disk when a storage directory is configured; `delete_session/1`
  removes it and forgets its ledger aggregate.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id), do: Pool.stop_session(session_id)

  @doc """
  Stops a session if it runs, removes its stored conversation and forgets its ledger aggregate.

  Returns `{:error, :not_found}` when there was neither a running session nor a file.
  """
  @spec delete_session(String.t()) :: :ok | {:error, :not_found | {:persistence, term()}}
  def delete_session(session_id) do
    exclusive(session_id, fn ->
      stopped = Pool.stop_session(session_id) == :ok
      Mead.Ledger.forget(session_id)
      directory = Store.directory()
      stored = directory != nil and Store.exists?(directory, session_id)

      with :ok <- delete_file(directory, session_id) do
        if stopped or stored, do: :ok, else: {:error, :not_found}
      end
    end)
  end

  defp delete_file(nil, _session_id), do: :ok

  defp delete_file(directory, session_id) do
    case Store.delete(directory, session_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persistence, reason}}
    end
  end

  @doc """
  Reads the ledger: the totals over every route, the totals per route and provider, and the most recent turns.

  ## Options

    * `:recent` - how many of the latest turns to include, newest first, from 0 to 100; defaults to 20.
    * `:ledger` - the ledger to read; defaults to `Mead.Ledger`.

  It never changes anything. When the ledger is not running it exits, as the ledger accessors do.
  """
  @spec usage(keyword()) :: %{totals: map(), routes: [map()], recent: [map()]}
  def usage(options \\ []) do
    options = validate_usage_options!(options)
    ledger = Keyword.fetch!(options, :ledger)

    routes =
      ledger
      |> Mead.Ledger.route_totals()
      |> Enum.map(fn {{route, provider}, totals} ->
        Map.merge(%{route: route, provider: provider}, totals)
      end)
      |> Enum.sort_by(&{Atom.to_string(&1.route), inspect(&1.provider)})

    %{
      totals: Mead.Ledger.totals(ledger),
      routes: routes,
      recent: Mead.Ledger.recent(Keyword.fetch!(options, :recent), ledger)
    }
  end

  @doc """
  Returns what the ledger counted for one session, or `{:error, :not_found}` for a session that has not completed a turn or was deleted.
  """
  @spec session_usage(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def session_usage(session_id, ledger \\ Mead.Ledger),
    do: Mead.Ledger.session_totals(session_id, ledger)

  defp validate_usage_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "options must be a keyword list, got: #{inspect(options)}"
    end

    options = Keyword.validate!(options, recent: @default_recent, ledger: Mead.Ledger)
    recent = Keyword.fetch!(options, :recent)

    unless is_integer(recent) and recent in 0..@maximum_recent//1 do
      raise ArgumentError,
            "recent must be an integer from 0 to #{@maximum_recent}, got: #{inspect(recent)}"
    end

    options
  end
end
