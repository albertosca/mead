defmodule Mead.MeadTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Turn

  @version_four_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  defp start_session!(options \\ []) do
    {:ok, session_id} = Mead.start_session(options)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  describe "start_session/1" do
    test "returns distinct UUID v4 ids and registers the whole conversation" do
      first = start_session!()
      second = start_session!()

      assert first =~ @version_four_pattern
      assert second =~ @version_four_pattern
      assert first != second

      for role <- [:supervisor, :history, :server] do
        assert is_pid(Session.whereis(first, role))
      end
    end

    test "rejects options it does not know" do
      assert_raise ArgumentError, fn -> Mead.start_session(handlr: Mead.Session.EchoHandler) end
    end

    test "rejects a turn timeout that is not a positive integer" do
      for invalid <- [0, -1, 1.5, "100", nil, :infinity] do
        assert_raise ArgumentError, ~r/turn_timeout/, fn ->
          Mead.start_session(turn_timeout: invalid)
        end
      end
    end

    test "rejects a handler that is not a module implementing handle_turn/2" do
      for invalid <- [Mead.NoSuchHandler, "handler", nil, Mead.UUID] do
        assert_raise ArgumentError, ~r/handler/, fn -> Mead.start_session(handler: invalid) end
      end
    end

    test "starts 100 sessions concurrently with distinct ids, all of them live" do
      session_ids =
        1..100
        |> Task.async_stream(fn _index -> Mead.start_session() end, max_concurrency: 20)
        |> Enum.map(fn {:ok, {:ok, session_id}} -> session_id end)

      on_exit(fn -> Enum.each(session_ids, &Mead.stop_session/1) end)

      assert length(Enum.uniq(session_ids)) == 100
      assert Enum.all?(session_ids, &is_pid(Session.whereis(&1, :server)))
    end
  end

  describe "submit_turn/2 and history/1" do
    test "record turns in chronological order" do
      session_id = start_session!()

      assert Mead.submit_turn(session_id, "first") == {:ok, "first"}
      assert Mead.submit_turn(session_id, "second") == {:ok, "second"}

      assert {:ok,
              [
                %Turn{input: "first", output: "first", status: :ok},
                %Turn{input: "second", output: "second", status: :ok}
              ]} = Mead.history(session_id)
    end
  end

  describe "unknown sessions" do
    test "every function answers :not_found" do
      unknown = Mead.UUID.generate()

      assert Mead.submit_turn(unknown, "hello") == {:error, :not_found}
      assert Mead.history(unknown) == {:error, :not_found}
      assert Mead.stop_session(unknown) == {:error, :not_found}
    end

    test "ids that are not session ids answer :not_found instead of crashing" do
      for odd_id <- [nil, "", 42, :atom, {:tuple}] do
        assert Mead.submit_turn(odd_id, "hello") == {:error, :not_found}
        assert Mead.history(odd_id) == {:error, :not_found}
        assert Mead.stop_session(odd_id) == {:error, :not_found}
      end
    end
  end

  describe "stop_session/1" do
    test "removes the conversation and discards its history" do
      session_id = start_session!()
      Mead.submit_turn(session_id, "hello")

      assert Mead.stop_session(session_id) == :ok

      wait_until(fn -> Session.whereis(session_id, :server) == nil end)
      assert Mead.history(session_id) == {:error, :not_found}
      assert Mead.submit_turn(session_id, "again") == {:error, :not_found}
    end
  end
end
