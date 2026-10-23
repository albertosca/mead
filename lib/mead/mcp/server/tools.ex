defmodule Mead.MCP.Server.Tools do
  @moduledoc """
  The four tools the MCP server offers: `start_session`, `submit_turn`, `history`, and
  `stop_session`. They are the only code of the server that touches the runtime, and they do it
  only through the public `Mead` API.

  A tool never raises for what a client can send. Arguments of the wrong type come back as
  `{:error, {:invalid_params, message}}`, which the dispatcher turns into a JSON-RPC error.
  What goes wrong while the tool runs (an unknown session, a failed turn, a timeout) comes back
  as an ordinary result with `"isError" => true` and a short fixed message: no stack trace, no
  provider text, no internal term.
  """

  @maximum_input_characters 100_000
  # The longest delay `Process.send_after/3` accepts on every platform; the same bound as `Mead`.
  @maximum_turn_timeout 4_294_967_295
  @routes %{"auto" => :auto, "local" => :local, "cloud" => :cloud}
  @inspect_options [limit: 50, printable_limit: 1_000]

  @type context :: %{allow_effect: boolean()}

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        "name" => "start_session",
        "description" => "Starts a conversation session and returns its id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "turn_timeout" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Milliseconds a single turn of this session may run."
            }
          }
        }
      },
      %{
        "name" => "submit_turn",
        "description" => "Runs one turn in a session and returns the reply.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{"type" => "string", "description" => "The id from start_session."},
            "input" => %{
              "type" => "string",
              "maxLength" => @maximum_input_characters,
              "description" => "What the user says in this turn."
            },
            "route" => %{
              "type" => "string",
              "enum" => ["auto", "local", "cloud"],
              "description" => "Where the turn is answered; defaults to auto."
            },
            "tools" => %{
              "type" => "string",
              "enum" => ["effect"],
              "description" =>
                "Also let the model use tools that have side effects. Only honoured when the operator enabled it."
            }
          },
          "required" => ["session_id", "input"]
        }
      },
      %{
        "name" => "history",
        "description" => "Returns the turns of a session as a JSON list.",
        "inputSchema" => session_schema()
      },
      %{
        "name" => "stop_session",
        "description" => "Stops a session and discards its history.",
        "inputSchema" => session_schema()
      }
    ]
  end

  defp session_schema do
    %{
      "type" => "object",
      "properties" => %{"session_id" => %{"type" => "string"}},
      "required" => ["session_id"]
    }
  end

  @spec call(term(), map(), context()) ::
          {:ok, map()} | {:error, :unknown_tool} | {:error, {:invalid_params, String.t()}}
  def call("start_session", arguments, _context), do: start_session(arguments)
  def call("submit_turn", arguments, context), do: submit_turn(arguments, context)
  def call("history", arguments, _context), do: history(arguments)
  def call("stop_session", arguments, _context), do: stop_session(arguments)
  def call(_name, _arguments, _context), do: {:error, :unknown_tool}

  defp start_session(arguments) do
    with {:ok, options} <- session_options(arguments) do
      case Mead.start_session(options) do
        {:ok, session_id} -> {:ok, success(session_id)}
        {:error, _reason} -> {:ok, failure("the session could not be started")}
      end
    end
  end

  defp session_options(arguments) do
    case Map.fetch(arguments, "turn_timeout") do
      :error ->
        {:ok, []}

      {:ok, turn_timeout}
      when is_integer(turn_timeout) and turn_timeout > 0 and
             turn_timeout <= @maximum_turn_timeout ->
        {:ok, [turn_timeout: turn_timeout]}

      {:ok, _other} ->
        invalid("turn_timeout must be a positive integer number of milliseconds")
    end
  end

  defp submit_turn(arguments, context) do
    with {:ok, session_id} <- fetch_session_id(arguments),
         {:ok, input} <- fetch_input(arguments),
         {:ok, route} <- fetch_route(arguments) do
      effect_requested = Map.get(arguments, "tools") == "effect"

      cond do
        effect_requested and not context.allow_effect ->
          {:ok, failure("effect tools are not enabled by the operator")}

        effect_requested ->
          {:ok, turn_result(Mead.submit_turn(session_id, input, route: route, tools: :effect))}

        true ->
          {:ok, turn_result(Mead.submit_turn(session_id, input, route: route))}
      end
    end
  end

  defp fetch_input(arguments) do
    case Map.get(arguments, "input") do
      input when is_binary(input) ->
        if String.length(input) <= @maximum_input_characters do
          {:ok, input}
        else
          invalid("input must be at most #{@maximum_input_characters} characters")
        end

      _other ->
        invalid("input must be a string")
    end
  end

  defp fetch_route(arguments) do
    case Map.fetch(arguments, "route") do
      :error ->
        {:ok, :auto}

      {:ok, name} when is_binary(name) ->
        case Map.fetch(@routes, name) do
          {:ok, route} -> {:ok, route}
          :error -> invalid("route must be one of auto, local, cloud")
        end

      {:ok, _other} ->
        invalid("route must be one of auto, local, cloud")
    end
  end

  defp turn_result({:ok, output}), do: success(text_of(output))
  defp turn_result({:error, reason}), do: failure(turn_failure(reason))

  defp turn_failure(:not_found), do: "unknown session"
  defp turn_failure(:session_stopped), do: "the session was stopped during the turn"
  defp turn_failure(:session_crashed), do: "the session crashed during the turn"
  defp turn_failure(:turn_in_progress), do: "a turn is already running in this session"
  defp turn_failure(:timeout), do: "the turn timed out"
  defp turn_failure({:failed, _reason}), do: "the turn failed"
  defp turn_failure(_other), do: "the turn did not complete"

  defp history(arguments) do
    with {:ok, session_id} <- fetch_session_id(arguments) do
      case Mead.history(session_id) do
        {:ok, turns} -> {:ok, success(turns |> Enum.map(&turn_entry/1) |> JSON.encode!())}
        {:error, :not_found} -> {:ok, failure("unknown session")}
      end
    end
  end

  defp turn_entry(turn) do
    %{
      "input" => text_of(turn.input),
      "output" => if(is_nil(turn.output), do: nil, else: text_of(turn.output)),
      "status" => Atom.to_string(turn.status),
      "started_at" => DateTime.to_iso8601(turn.started_at)
    }
  end

  defp stop_session(arguments) do
    with {:ok, session_id} <- fetch_session_id(arguments) do
      case Mead.stop_session(session_id) do
        :ok -> {:ok, success("stopped")}
        {:error, :not_found} -> {:ok, failure("unknown session")}
      end
    end
  end

  defp fetch_session_id(arguments) do
    case Map.get(arguments, "session_id") do
      session_id when is_binary(session_id) -> {:ok, session_id}
      _other -> invalid("session_id must be a string")
    end
  end

  # A handler may return anything, and a string that is not valid UTF-8 would make the JSON
  # encoder raise on the way out. Show such values as inspected text instead.
  defp text_of(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value, @inspect_options)
  end

  defp text_of(value), do: inspect(value, @inspect_options)

  defp success(text), do: result(text, false)
  defp failure(text), do: result(text, true)

  defp result(text, is_error) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error}
  end

  defp invalid(message), do: {:error, {:invalid_params, message}}
end
