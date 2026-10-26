defmodule Mead.Deck.ConversationTest do
  # Sets global :storage and :router settings and talks to a real listener.
  use ExUnit.Case, async: false

  alias Mead.Test.DeckServer
  alias Mead.Test.FakeProvider
  alias Mead.Test.WebSocketClient

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous = for key <- [:storage, :router], do: {key, Application.get_env(:mead, key)}

    Application.put_env(:mead, :storage, directory: directory)

    slot =
      {FakeProvider,
       test_pid: self(), result: {:ok, %{text: "stub answer", usage: FakeProvider.usage()}}}

    Application.put_env(:mead, :router, slots: [local: slot, cloud: slot])

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:mead, key),
          else: Application.put_env(:mead, key, value)
      end
    end)

    # No :session_options override: the session is created with the real router as its handler.
    %{
      server: DeckServer.start(directory, [], session_options: [handler: Mead.Router]),
      directory: directory
    }
  end

  test "a conversation through the real router replays after the session is stopped and resumed",
       %{server: server, directory: directory} do
    %{"ticket" => ticket, "session_id" => session_id} = DeckServer.ticket(server)

    client = DeckServer.open(server, ticket)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")
    client = DeckServer.send_prompt(client, "list my tasks", "m-1")

    {client, accepted} = WebSocketClient.receive_type(client, "prompt.accepted")
    {client, delta} = WebSocketClient.receive_type(client, "text.delta")
    assert delta["payload"]["text"] == "stub answer"

    {client, tokens_in} = WebSocketClient.receive_type(client, "metric.updated")
    {client, tokens_out} = WebSocketClient.receive_type(client, "metric.updated")
    assert {tokens_in["payload"]["key"], tokens_in["payload"]["value"]} == {"tokens_in", 5}
    assert {tokens_out["payload"]["key"], tokens_out["payload"]["value"]} == {"tokens_out", 3}
    assert_received {:provider_called, _messages}
    WebSocketClient.close(client)

    :ok = Mead.stop_session(session_id)
    assert File.exists?(Path.join(directory, session_id <> ".events"))

    %{"ticket" => next_ticket} = DeckServer.ticket(server, session_id)
    client = DeckServer.open(server, next_ticket, 0)
    {client, _snapshot} = WebSocketClient.receive_type(client, "session.snapshot")

    {client, replayed_accepted} = WebSocketClient.receive_type(client, "prompt.accepted")
    {_client, replayed_delta} = WebSocketClient.receive_type(client, "text.delta")
    assert replayed_accepted == accepted
    assert replayed_delta == delta

    :ok = Mead.delete_session(session_id)
    refute File.exists?(Path.join(directory, session_id <> ".events"))
  end
end
