defmodule Mead.RouterTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Session.Turn
  alias Mead.Test.FakeProvider

  defp slots(overrides \\ []) do
    test_pid = self()

    Keyword.merge(
      [
        local:
          {FakeProvider,
           test_pid: test_pid, result: {:ok, %{text: "local reply", usage: FakeProvider.usage()}}},
        cloud:
          {FakeProvider,
           test_pid: test_pid, result: {:ok, %{text: "cloud reply", usage: FakeProvider.usage()}}}
      ],
      overrides
    )
  end

  defp completed(input, output), do: %Turn{Turn.start(input) | status: :ok, output: output}

  describe "route choice" do
    test "a forced route wins over what the classifier would pick" do
      assert Router.route([], "list my tasks", [route: :cloud], slots()) == {:ok, "cloud reply"}
      assert Router.route([], "explain why", [route: :local], slots()) == {:ok, "local reply"}
    end

    test "auto asks the classifier" do
      assert Router.route([], "list my tasks", [route: :auto], slots()) == {:ok, "local reply"}
      assert Router.route([], "explain why", [], slots()) == {:ok, "cloud reply"}
    end
  end

  describe "an empty slot" do
    test "fails the turn without calling any provider, and never falls back to the other slot" do
      only_cloud = slots(local: nil)

      assert Router.route([], "list my tasks", [], only_cloud) == {:error, :local_unavailable}

      assert Router.route([], "list my tasks", [route: :local], only_cloud) ==
               {:error, :local_unavailable}

      refute_received {:provider_called, _messages}

      only_local = slots(cloud: nil)
      assert Router.route([], "explain why", [], only_local) == {:error, :cloud_unavailable}
      refute_received {:provider_called, _messages}
    end

    test "no slots configured at all" do
      assert Router.route([], "hello", [], []) == {:error, :cloud_unavailable}
    end
  end

  describe "the messages sent to the provider" do
    test "carry the completed text turns, oldest first, then the new input" do
      history = [completed("one", "uno"), completed("two", "dos")]

      Router.route(history, "three", [route: :cloud], slots())

      assert_received {:provider_called, messages}

      assert messages == [
               %{role: :user, content: "one"},
               %{role: :assistant, content: "uno"},
               %{role: :user, content: "two"},
               %{role: :assistant, content: "dos"},
               %{role: :user, content: "three"}
             ]
    end

    test "leave out failed, timed-out, interrupted, and non-text turns" do
      history = [
        %Turn{Turn.start("failed input") | status: :failed, output: "quota exceeded"},
        %Turn{Turn.start("slow input") | status: :timeout, output: "partial"},
        %Turn{Turn.start("cut input") | status: :interrupted, output: "partial"},
        %Turn{Turn.start("running input") | status: :in_progress, output: "partial"},
        completed({:structured, :input}, "text"),
        completed("text", {:structured, :output}),
        completed("kept", "kept reply")
      ]

      Router.route(history, "now", [route: :cloud], slots())

      assert_received {:provider_called, messages}

      assert messages == [
               %{role: :user, content: "kept"},
               %{role: :assistant, content: "kept reply"},
               %{role: :user, content: "now"}
             ]
    end
  end

  describe "provider results" do
    test "an error from the provider is passed on as the reason" do
      failing =
        slots(cloud: {FakeProvider, test_pid: self(), result: {:error, {:http_status, 503}}})

      assert Router.route([], "explain", [], failing) == {:error, {:http_status, 503}}
    end

    test "an input that is not text fails without calling the provider" do
      assert Router.route([], {:structured, :input}, [], slots()) == {:error, :unsupported_input}
      refute_received {:provider_called, _messages}
    end
  end

  describe "a misconfigured slot" do
    test "fails the turn with :invalid_slot instead of crashing or echoing its content" do
      for invalid <- [{FakeProvider, %{api_key: "sk-secret"}}, :nonsense, {"module", []}] do
        assert Router.route([], "explain", [], slots(cloud: invalid)) == {:error, :invalid_slot}
      end

      assert Router.route([], "explain", [], %{cloud: {FakeProvider, []}}) ==
               {:error, :invalid_slot}

      refute_received {:provider_called, _messages}
    end
  end

  describe "text that is not valid UTF-8" do
    test "fails without calling the provider" do
      assert Router.route([], <<255, "x">>, [route: :cloud], slots()) ==
               {:error, :unsupported_input}

      refute_received {:provider_called, _messages}
    end
  end

  describe "a long conversation" do
    test "replays only the most recent twenty exchanges" do
      history = for index <- 1..25, do: completed("question #{index}", "answer #{index}")

      Router.route(history, "now", [route: :cloud], slots())

      assert_received {:provider_called, messages}
      assert length(messages) == 41
      assert hd(messages) == %{role: :user, content: "question 6"}
      assert List.last(messages) == %{role: :user, content: "now"}
    end
  end

  describe "the route event" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:mead, :router, :route],
        fn _event, measurements, metadata, _config ->
          # The handler is global and runs in the emitting process: ignore events from other
          # tests' turns running concurrently.
          if self() == test_pid, do: send(test_pid, {:route_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "reports the route, its source, the provider, the status, and the tokens on success" do
      Router.route([], "list my tasks", [], slots())

      assert_received {:route_event, measurements, metadata}
      assert measurements.input_tokens == 5
      assert measurements.output_tokens == 3
      assert is_integer(measurements.duration) and measurements.duration >= 0

      assert metadata == %{
               route: :local,
               route_source: :classified,
               provider: FakeProvider,
               status: :ok,
               session_id: nil
             }
    end

    test "reports the session id the server passed in the options" do
      Router.route([], "list my tasks", [session_id: "session-1"], slots())

      assert_received {:route_event, _measurements, metadata}
      assert metadata.session_id == "session-1"
    end

    test "ignores a route event emitted by another process" do
      Task.await(
        Task.async(fn -> Router.route([], "list my tasks", [session_id: "other"], slots()) end)
      )

      refute_received {:route_event, _measurements, _metadata}
    end

    test "reports a forced route and zero tokens on failure" do
      failing = slots(cloud: {FakeProvider, test_pid: self(), result: {:error, :timeout}})

      Router.route([], "list my tasks", [route: :cloud], failing)

      assert_received {:route_event, measurements, metadata}
      assert %{input_tokens: 0, output_tokens: 0} = measurements
      assert %{route: :cloud, route_source: :forced, status: :error} = metadata
    end

    test "reports an empty slot with no provider" do
      Router.route([], "list my tasks", [], slots(local: nil))

      assert_received {:route_event, _measurements, metadata}
      assert %{route: :local, provider: nil, status: :error} = metadata
    end
  end
end
