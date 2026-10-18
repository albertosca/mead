defmodule Mead do
  @moduledoc """
  Public API of the `mead` runtime: isolated, supervised conversation sessions.

  Each session keeps its history across crashes of its server process. The code that produces
  the output of a turn is a `Mead.Session.TurnHandler`, chosen per session.
  """

  alias Mead.Session
  alias Mead.Session.EchoHandler
  alias Mead.Session.History
  alias Mead.Session.Pool
  alias Mead.Session.Turn

  @default_turn_timeout 30_000
  @routes [:auto, :local, :cloud]
  # The longest delay `Process.send_after/3` accepts on every platform.
  @maximum_turn_timeout 4_294_967_295

  @doc """
  Starts a session and returns its id.

  ## Options

    * `:handler` - module implementing `Mead.Session.TurnHandler`; defaults to the
      `:turn_handler` application setting, then to `Mead.Session.EchoHandler`.
    * `:turn_timeout` - milliseconds a single turn may run; defaults to the `:turn_timeout`
      application setting, then to 30 seconds.
  """
  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(options \\ []) do
    options = validate_options!(options)
    session_id = Mead.UUID.generate()

    session_options = [
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
        |> validate_turn_timeout!()
    ]

    case Pool.start_session(session_options) do
      {:ok, _pid} -> {:ok, session_id}
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
      Keyword.validate!(options, route: :auto)
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

  @doc "Stops a session and discards its history."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id), do: Pool.stop_session(session_id)
end
