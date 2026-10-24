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

    test "rejects a turn timeout too large for a timer" do
      for invalid <- [4_294_967_296, Integer.pow(2, 63)] do
        assert_raise ArgumentError, ~r/turn_timeout/, fn ->
          Mead.start_session(turn_timeout: invalid)
        end
      end

      {:ok, session_id} = Mead.start_session(turn_timeout: 4_294_967_295)
      on_exit(fn -> Mead.stop_session(session_id) end)
      assert Mead.submit_turn(session_id, "still works") == {:ok, "still works"}
    end

    test "rejects options that are not a keyword list" do
      for invalid <- [%{}, nil, "options", [:handler]] do
        assert_raise ArgumentError, ~r/keyword list/, fn -> Mead.start_session(invalid) end
      end
    end

    test "rejects a handler that is not a module implementing handle_turn/3" do
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

  describe "submit_turn/3 with the tools option" do
    test "hands tools: :effect to the handler" do
      session_id = start_session!(handler: Mead.Test.ScriptedHandler)

      assert {:ok, :reported} =
               Mead.submit_turn(session_id, {:report_options, self()}, tools: :effect)

      assert_receive {:handler_options, options}
      assert options[:tools] == :effect
    end

    test "leaves the key out when the option is not given" do
      session_id = start_session!(handler: Mead.Test.ScriptedHandler)

      assert {:ok, :reported} = Mead.submit_turn(session_id, {:report_options, self()})

      assert_receive {:handler_options, options}
      refute Keyword.has_key?(options, :tools)
    end

    test "an unknown option is still refused" do
      session_id = start_session!()

      assert_raise ArgumentError, fn -> Mead.submit_turn(session_id, "hi", unknown: true) end
    end
  end

  describe "submit_turn/3 options" do
    test "the route reaches the handler" do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.ScriptedHandler, turn_timeout: 30_000)

      on_exit(fn -> Mead.stop_session(session_id) end)

      assert Mead.submit_turn(session_id, {:report_options, self()}, route: :cloud) ==
               {:ok, :reported}

      assert_received {:handler_options, options}
      assert options[:route] == :cloud
    end

    test "the server tells the handler which session the turn belongs to" do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.ScriptedHandler, turn_timeout: 30_000)

      on_exit(fn -> Mead.stop_session(session_id) end)

      Mead.submit_turn(session_id, {:report_options, self()})
      assert_received {:handler_options, options}
      assert options[:session_id] == session_id
    end

    test "a caller cannot choose the session id the handler sees" do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.ScriptedHandler, turn_timeout: 30_000)

      on_exit(fn -> Mead.stop_session(session_id) end)

      assert_raise ArgumentError, fn ->
        Mead.submit_turn(session_id, {:report_options, self()}, session_id: "forged")
      end

      refute_received {:handler_options, _options}
    end

    test "the route defaults to :auto" do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.ScriptedHandler, turn_timeout: 30_000)

      on_exit(fn -> Mead.stop_session(session_id) end)

      Mead.submit_turn(session_id, {:report_options, self()})
      assert_received {:handler_options, options}
      assert options[:route] == :auto
    end

    test "an unknown route is rejected before any turn is recorded" do
      session_id = start_session!()

      for invalid <- [:nowhere, "cloud", nil, 1] do
        assert Mead.submit_turn(session_id, "hello", route: invalid) == {:error, :invalid_route}
      end

      assert Mead.history(session_id) == {:ok, []}
    end

    test "options that are not a known keyword list raise" do
      session_id = start_session!()

      for invalid <- [%{}, nil, "options", [:route], [rout: :cloud]] do
        assert_raise ArgumentError, fn -> Mead.submit_turn(session_id, "hello", invalid) end
      end
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
    test "a caller waiting on a running turn is told the session was stopped, not that it crashed" do
      {:ok, session_id} =
        Mead.start_session(handler: Mead.Test.ScriptedHandler, turn_timeout: 30_000)

      test_pid = self()
      waiting_caller = Task.async(fn -> Mead.submit_turn(session_id, {:block, test_pid}) end)
      assert_receive {:handler_started, _handler_pid}

      assert Mead.stop_session(session_id) == :ok
      assert Task.await(waiting_caller) == {:error, :session_stopped}
    end

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
