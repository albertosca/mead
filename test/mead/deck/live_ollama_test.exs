defmodule Mead.Deck.LiveOllamaTest.Hub do
  @moduledoc false

  # Points the router at a hub with its own name, since the application owns the default one.
  def tools_for(options), do: Mead.MCP.Hub.tools_for(options, :live_ollama_hub)

  def call_tool(name, arguments, options),
    do: Mead.MCP.Hub.call_tool(name, arguments, options, :live_ollama_hub)

  def describe_tool(name, options),
    do: Mead.MCP.Hub.describe_tool(name, options, :live_ollama_hub)
end

defmodule Mead.Deck.LiveOllamaTest.Handler do
  @moduledoc false
  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(history, input, options) do
    slot = {Mead.Provider.Ollama, model: "llama3.2:3b", receive_timeout: 120_000}

    Mead.Router.route(
      history,
      input,
      options,
      [local: slot, cloud: slot],
      Mead.Deck.LiveOllamaTest.Hub
    )
  end
end

defmodule Mead.Deck.LiveOllamaTest do
  # Needs `ollama serve` with llama3.2:3b and starts a real `elixir` child process, so it runs only
  # on request: mix test --include live test/mead/deck/live_ollama_test.exs
  use ExUnit.Case, async: false

  alias Mead.MCP.Hub
  alias Mead.Test.DeckServer
  alias Mead.Test.WebSocketClient

  @moduletag :live
  @moduletag :tmp_dir
  @stub Path.expand("../../support/stub_mcp_server.exs", __DIR__)

  setup %{tmp_dir: directory} do
    previous = Application.get_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mead, :storage)
        value -> Application.put_env(:mead, :storage, value)
      end
    end)

    :ok
  end

  defp next_event(client, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    {client, envelope} = WebSocketClient.receive_json(client, remaining)
    assert is_map(envelope), "no event before the deadline: #{inspect(envelope)}"
    if envelope["type"] == "heartbeat", do: next_event(client, deadline), else: {client, envelope}
  end

  # Reads the turn to its last metric, allowing every permission request; returns the figures.
  defp drive(
         client,
         started,
         deadline,
         figures \\ %{deltas: 0, permissions: 0, first_delta_ms: nil}
       ) do
    {client, envelope} = next_event(client, deadline)
    elapsed = System.monotonic_time(:millisecond) - started

    figures =
      case envelope["type"] do
        "text.delta" ->
          %{
            figures
            | deltas: figures.deltas + 1,
              first_delta_ms: figures.first_delta_ms || elapsed
          }

        "permission.requested" ->
          %{figures | permissions: figures.permissions + 1}

        _other ->
          figures
      end

    cond do
      envelope["type"] == "permission.requested" ->
        client =
          WebSocketClient.send_json(client, %{
            "type" => "permission.respond",
            "payload" => %{
              "request_id" => envelope["payload"]["request_id"],
              "option_id" => "allow_once"
            }
          })

        drive(client, started, deadline, figures)

      envelope["type"] == "metric.updated" and envelope["payload"]["key"] == "tokens_out" ->
        {client, Map.put(figures, :total_ms, elapsed)}

      true ->
        drive(client, started, deadline, figures)
    end
  end

  test "a real model streams a turn through the deck, with a real tool behind a permission",
       %{tmp_dir: directory} do
    start_supervised!(
      {Hub,
       [
         name: :live_ollama_hub,
         servers: [
           stub: [
             transport:
               {:stdio, command: System.find_executable("elixir"), arguments: [@stub, "live"]},
             tools: [echo: :read, fail: :read, write_note: :effect]
           ]
         ]
       ]}
    )

    Mead.TestHelpers.wait_until(
      fn -> Hub.tools_for([tools: :effect], :live_ollama_hub) != [] end,
      60_000
    )

    server =
      DeckServer.start(directory, [],
        session_options: [handler: Mead.Deck.LiveOllamaTest.Handler, turn_timeout: 150_000]
      )

    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)
    on_exit(fn -> Mead.stop_session(session_id) end)
    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    prompt =
      "Call the stub__write_note tool once, then tell me in one short sentence that the note is written."

    started = System.monotonic_time(:millisecond)
    client = DeckServer.send_prompt(client, prompt)
    {_client, figures} = drive(client, started, started + 150_000)

    IO.puts("live figures: #{inspect(figures)}")
    assert figures.deltas >= 1
  end
end
