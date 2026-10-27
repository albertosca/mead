defmodule Mead.Deck.SocketIdleClockTest do
  # Drives the WebSock callbacks directly, so the channel can be made slow without any race.
  use ExUnit.Case, async: true

  alias Mead.Deck.Configuration
  alias Mead.Deck.Socket

  @resume_frame JSON.encode!(%{
                  "type" => "session.resume",
                  "payload" => %{"last_sequence" => 0}
                })

  # A channel that answers every call, but only after `delay_ms`.
  defp slow_channel(delay_ms) do
    spawn_link(fn -> serve(delay_ms) end)
  end

  defp serve(delay_ms) do
    receive do
      {:"$gen_call", from, _request} ->
        Process.sleep(delay_ms)
        GenServer.reply(from, :ok)
        serve(delay_ms)
    end
  end

  defp socket_state(channel) do
    {:ok, configuration} =
      Configuration.load(token: "token", heartbeat_ms: 50, idle_timeout_ms: 200)

    {:ok, state} =
      Socket.init(%{channel: channel, session_id: "session", configuration: configuration})

    state
  end

  test "time spent handling the resume does not count as silence from the client" do
    state = socket_state(slow_channel(300))

    {:ok, resumed} = Socket.handle_in({@resume_frame, [opcode: :text]}, state)

    # The client spoke 300 ms ago by the clock of the frame's arrival, but the 300 ms were the
    # channel's, not the client's: its first heartbeat must find a live socket, not an idle one.
    assert {:push, [{:text, _heartbeat}, {:ping, ""}], _state} =
             Socket.handle_info(:heartbeat, resumed)
  end

  test "a client that stays silent past the idle timeout is still closed" do
    state = socket_state(slow_channel(0))

    {:ok, resumed} = Socket.handle_in({@resume_frame, [opcode: :text]}, state)
    Process.sleep(250)

    assert {:stop, :normal, {1001, "idle"}, _state} = Socket.handle_info(:heartbeat, resumed)
  end
end
