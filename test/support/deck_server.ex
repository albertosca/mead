defmodule Mead.Test.DeckServer do
  @moduledoc false

  # Starts the real shared listener on a free port with the deck enabled, and speaks to it the way
  # a deck does: `POST /deck/ticket` over HTTP, then `GET /deck/socket` upgraded to a WebSocket.

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Mead.Test.WebSocketClient

  @token "deck-server-test-token"

  def token, do: @token

  @doc """
  Starts the listener and returns `%{port: port, token: token}`. `deck_settings` are merged over a
  fast test configuration, `deck_options` go to `Mead.Deck.Plug`, `mcp_settings` to the listener.
  """
  def start(storage_directory, deck_settings \\ [], deck_options \\ [], mcp_settings \\ []) do
    name = :"deck_server_#{System.unique_integer([:positive])}"

    deck_settings = Keyword.merge([token: @token], deck_settings)

    deck_options =
      Keyword.merge(
        [
          session_options: [handler: Mead.Test.DeckHandler, turn_timeout: 5_000],
          storage_directory: storage_directory
        ],
        deck_options
      )

    start_supervised!(
      Supervisor.child_spec(
        {Mead.MCP.Server,
         name: name,
         settings: Keyword.merge([port: 0], mcp_settings),
         deck_settings: deck_settings,
         deck_options: deck_options},
        id: name
      )
    )

    {:ok, port} = Mead.MCP.Server.port(name)
    %{port: port, token: @token}
  end

  @doc "Asks for a ticket; `body` is nil (no body) or a map sent as JSON. Returns the `Req.Response`."
  def request_ticket(server, body \\ nil, token \\ nil) do
    options = [
      headers: [authorization: "Bearer " <> (token || server.token)],
      retry: false
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options
    Req.post!("http://127.0.0.1:#{server.port}/deck/ticket", options)
  end

  @doc "A ticket for a new session (or for `session_id`): `%{\"ticket\" => _, \"session_id\" => _}`."
  def ticket(server, session_id \\ nil) do
    body = if session_id, do: %{"session_id" => session_id}
    %Req.Response{status: 200, body: body} = request_ticket(server, body)
    body
  end

  @doc "Opens the WebSocket for `ticket` and sends `session.resume` from `last_sequence`."
  def open(server, ticket, last_sequence \\ 0, headers \\ []) do
    {:ok, client} =
      WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket, headers)

    WebSocketClient.send_json(client, %{
      "type" => "session.resume",
      "payload" => %{"last_sequence" => last_sequence}
    })
  end

  @doc "Like `open/2`, with the `device_id` the client names itself by."
  def open_as(server, ticket, device_id) do
    {:ok, client} = WebSocketClient.connect(server.port, "/deck/socket?ticket=" <> ticket)

    WebSocketClient.send_json(client, %{
      "type" => "session.resume",
      "payload" => %{"last_sequence" => 0, "device_id" => device_id}
    })
  end

  @doc "Sends `prompt.send` with a fresh message id."
  def send_prompt(client, text, message_id \\ nil) do
    WebSocketClient.send_json(client, %{
      "type" => "prompt.send",
      "payload" => %{
        "client_message_id" => message_id || "message-#{System.unique_integer([:positive])}",
        "text" => text
      }
    })
  end
end
