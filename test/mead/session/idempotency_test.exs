defmodule Mead.Session.IdempotencyTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Turn
  alias Mead.Test.ScriptedHandler

  @moduletag timeout: 30_000
  @moduletag :capture_log

  defp start_session!(options \\ []) do
    {:ok, session_id} =
      Mead.start_session(Keyword.merge([handler: ScriptedHandler, turn_timeout: 20_000], options))

    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  defp waiter_count(session_id) do
    case :sys.get_state(Session.whereis(session_id, :server)) do
      %{running: %{waiters: waiters}} -> length(waiters)
      _idle -> 0
    end
  end

  describe "a repeated key with the same input" do
    test "after a successful turn returns the stored output and runs nothing" do
      session_id = start_session!()

      assert Mead.submit_turn(session_id, {:echo, "one"}, client_turn_id: "key-1") == {:ok, "one"}
      assert Mead.submit_turn(session_id, {:echo, "one"}, client_turn_id: "key-1") == {:ok, "one"}

      assert {:ok, [%Turn{client_turn_id: "key-1", status: :ok}]} = Mead.history(session_id)
    end

    test "after a failed turn returns the same failure and runs nothing" do
      session_id = start_session!()

      assert Mead.submit_turn(session_id, {:error, :quota}, client_turn_id: "key-1") ==
               {:error, {:failed, :quota}}

      assert Mead.submit_turn(session_id, {:error, :quota}, client_turn_id: "key-1") ==
               {:error, {:failed, :quota}}

      assert {:ok, [%Turn{status: :failed}]} = Mead.history(session_id)
    end

    test "after a timed-out turn returns the timeout and runs nothing" do
      session_id = start_session!(turn_timeout: 50)
      input = {:block, self()}

      assert Mead.submit_turn(session_id, input, client_turn_id: "key-1") == {:error, :timeout}
      assert_receive {:handler_started, _handler_pid}

      assert Mead.submit_turn(session_id, input, client_turn_id: "key-1") == {:error, :timeout}
      refute_receive {:handler_started, _handler_pid}, 100

      assert {:ok, [%Turn{status: :timeout}]} = Mead.history(session_id)
    end

    test "after a turn interrupted by a server crash returns :interrupted and runs nothing" do
      session_id = start_session!()
      test_pid = self()
      input = {:block, test_pid}

      spawn(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      assert_receive {:handler_started, _handler_pid}

      old_server = Session.whereis(session_id, :server)
      Process.exit(old_server, :kill)

      wait_until(fn ->
        match?({:ok, [%Turn{status: :interrupted}]}, Mead.history(session_id)) and
          Session.whereis(session_id, :server) not in [nil, old_server]
      end)

      assert Mead.submit_turn(session_id, input, client_turn_id: "key-1") ==
               {:error, :interrupted}

      refute_receive {:handler_started, _handler_pid}, 100
      assert {:ok, [%Turn{status: :interrupted}]} = Mead.history(session_id)
    end

    test "while the turn runs joins it, and both callers get the same reply" do
      session_id = start_session!()
      input = {:block, self()}

      first = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      assert_receive {:handler_started, handler_pid}

      second = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      wait_until(fn -> waiter_count(session_id) == 2 end)
      refute_receive {:handler_started, _handler_pid}, 100

      send(handler_pid, :release)
      assert Task.await(first) == {:ok, :released}
      assert Task.await(second) == {:ok, :released}
      assert {:ok, [%Turn{status: :ok, output: :released}]} = Mead.history(session_id)
    end

    test "a waiter that dies does not keep the other waiter from its reply" do
      session_id = start_session!()
      input = {:block, self()}

      {:ok, doomed} =
        Task.start(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)

      assert_receive {:handler_started, handler_pid}

      survivor =
        Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)

      wait_until(fn -> waiter_count(session_id) == 2 end)
      Process.exit(doomed, :kill)
      send(handler_pid, :release)

      assert Task.await(survivor) == {:ok, :released}
    end

    test "a waiter that dies is dropped while the turn still runs" do
      session_id = start_session!()
      input = {:block, self()}

      first = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      assert_receive {:handler_started, handler_pid}

      {:ok, doomed} =
        Task.start(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)

      wait_until(fn -> waiter_count(session_id) == 2 end)
      Process.exit(doomed, :kill)
      wait_until(fn -> waiter_count(session_id) == 1 end)

      send(handler_pid, :release)
      assert Task.await(first) == {:ok, :released}
    end

    test "every waiter gets the timeout when the turn runs out of time" do
      session_id = start_session!(turn_timeout: 300)
      input = {:block, self()}

      first = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      assert_receive {:handler_started, _handler_pid}

      second = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      wait_until(fn -> waiter_count(session_id) == 2 end)

      assert Task.await(first) == {:error, :timeout}
      assert Task.await(second) == {:error, :timeout}
      assert {:ok, [%Turn{status: :timeout}]} = Mead.history(session_id)
    end
  end

  describe "History.find_by_client_turn_id/2" do
    test "finds the turn recorded under the key, and nil for a key never used" do
      session_id = start_session!()
      assert {:ok, "one"} = Mead.submit_turn(session_id, {:echo, "one"}, client_turn_id: "key-1")
      assert {:ok, "two"} = Mead.submit_turn(session_id, {:echo, "two"})

      assert %Turn{client_turn_id: "key-1", output: "one"} =
               Mead.Session.History.find_by_client_turn_id(session_id, "key-1")

      assert Mead.Session.History.find_by_client_turn_id(session_id, "key-2") == nil
    end
  end

  describe "a repeated key with a different input" do
    test "against an ended turn is a conflict that describes the original turn" do
      session_id = start_session!()
      assert {:ok, "one"} = Mead.submit_turn(session_id, {:echo, "one"}, client_turn_id: "key-1")
      {:ok, [%Turn{started_at: started_at}]} = Mead.history(session_id)

      assert Mead.submit_turn(session_id, {:echo, "two"}, client_turn_id: "key-1") ==
               {:error,
                {:client_turn_id_conflict,
                 %{
                   client_turn_id: "key-1",
                   input: {:echo, "one"},
                   status: :ok,
                   started_at: started_at
                 }}}

      assert {:ok, [_only_turn]} = Mead.history(session_id)
    end

    test "against the running turn is a conflict with status :in_progress" do
      session_id = start_session!()
      input = {:block, self()}

      running = Task.async(fn -> Mead.submit_turn(session_id, input, client_turn_id: "key-1") end)
      assert_receive {:handler_started, handler_pid}

      assert {:error, {:client_turn_id_conflict, %{status: :in_progress, input: ^input}}} =
               Mead.submit_turn(session_id, {:echo, "other"}, client_turn_id: "key-1")

      send(handler_pid, :release)
      assert Task.await(running) == {:ok, :released}
    end
  end

  describe "keys that do not repeat" do
    test "a new key while another turn runs is still :turn_in_progress" do
      session_id = start_session!()
      test_pid = self()

      running =
        Task.async(fn ->
          Mead.submit_turn(session_id, {:block, test_pid}, client_turn_id: "first")
        end)

      assert_receive {:handler_started, handler_pid}

      assert Mead.submit_turn(session_id, {:echo, "other"}, client_turn_id: "second") ==
               {:error, :turn_in_progress}

      send(handler_pid, :release)
      assert Task.await(running) == {:ok, :released}
    end

    test "the same input without a key runs every time" do
      session_id = start_session!()

      assert Mead.submit_turn(session_id, {:echo, "same"}) == {:ok, "same"}
      assert Mead.submit_turn(session_id, {:echo, "same"}) == {:ok, "same"}
      assert {:ok, [_first, _second]} = Mead.history(session_id)
    end

    test "the same key in another session is independent" do
      first_session = start_session!()
      second_session = start_session!()

      assert {:ok, "one"} =
               Mead.submit_turn(first_session, {:echo, "one"}, client_turn_id: "key-1")

      assert {:ok, "two"} =
               Mead.submit_turn(second_session, {:echo, "two"}, client_turn_id: "key-1")
    end

    test "the key is not handed to the handler" do
      session_id = start_session!()

      assert {:ok, :reported} =
               Mead.submit_turn(session_id, {:report_options, self()}, client_turn_id: "key-1")

      assert_receive {:handler_options, options}
      refute Keyword.has_key?(options, :client_turn_id)
    end
  end

  describe "key validation" do
    test "accepts 1 to 128 characters, counting code points and not bytes" do
      session_id = start_session!()

      for key <- ["a", String.duplicate("a", 128), String.duplicate("é", 128), "retry 42/ü"] do
        assert {:ok, ^key} = Mead.submit_turn(session_id, {:echo, key}, client_turn_id: key)
      end
    end

    test "refuses anything else before a turn is recorded" do
      session_id = start_session!()

      invalid = [
        "",
        String.duplicate("a", 129),
        String.duplicate("é", 129),
        # One grapheme each, but two code points: 256 code points in all.
        String.duplicate("é", 128),
        # A single grapheme of 50 001 code points.
        "a" <> String.duplicate("́", 50_000),
        "line\nbreak",
        "tab\there",
        "nul\u0000",
        "delete\u007F",
        <<255, 254>>,
        :key,
        42,
        nil
      ]

      for key <- invalid do
        assert Mead.submit_turn(session_id, {:echo, "x"}, client_turn_id: key) ==
                 {:error, :invalid_client_turn_id},
               "expected #{inspect(key)} to be refused"
      end

      assert Mead.history(session_id) == {:ok, []}
    end

    test "valid_client_turn_id?/1 answers the same rule" do
      assert Mead.valid_client_turn_id?("key-1")
      refute Mead.valid_client_turn_id?("")
      refute Mead.valid_client_turn_id?("a\nb")
      refute Mead.valid_client_turn_id?(:key)
    end
  end
end
