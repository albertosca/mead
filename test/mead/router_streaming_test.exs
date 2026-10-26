defmodule Mead.RouterStreamingTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.{FakeHub, FakeInteraction, FakeProvider, StreamingProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}
  @call {"call-1", "files__read_file", %{"path" => "/a"}}

  defp script(steps), do: start_supervised!({Agent, fn -> steps end}, id: make_ref())

  defp slots(provider, steps, extra \\ []) do
    provider_options = [test_pid: self(), script: script(steps)] ++ extra
    [cloud: {provider, provider_options}, local: {provider, provider_options}]
  end

  defp route(provider, steps, options \\ [], extra \\ [], tools \\ [@tool]) do
    FakeHub.configure(
      test_pid: self(),
      tools: tools,
      results: %{"files__read_file" => {:ok, %{content: "body", is_error: false}}}
    )

    context = FakeInteraction.start([:allow])
    options = Keyword.merge([route: :cloud, interaction: {FakeInteraction, context}], options)
    Router.route([], "hello", options, slots(provider, steps, extra), FakeHub)
  end

  defp deltas(collected \\ []) do
    receive do
      {:text_delta, text} -> deltas(collected ++ [text])
    after
      0 -> collected
    end
  end

  defp capture_telemetry do
    test_pid = self()
    handler = "router-streaming-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mead, :router, :route],
      fn _event, measurements, metadata, _config ->
        # Handlers run in the emitting process; tests running side by side must not hear each other.
        if self() == test_pid, do: send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "fragments reach the interaction in order and join to the returned text" do
    steps = [FakeProvider.text_step("fake reply")]

    assert {:ok, "fake reply"} = route(StreamingProvider, steps)
    assert deltas() == ["fak", "e r", "epl", "y"]
  end

  test "a turn without tools streams through converse_stream with no tools" do
    steps = [FakeProvider.text_step("fake reply")]

    assert {:ok, "fake reply"} = route(StreamingProvider, steps, [], [], [])
    assert deltas() |> Enum.join() == "fake reply"
  end

  test "a tool loop streams the text of each model call" do
    steps = [FakeProvider.tool_step([@call]), FakeProvider.text_step("done")]

    assert {:ok, "done"} = route(StreamingProvider, steps)
    assert deltas() == ["don", "e"]
  end

  test "telemetry equals the non-streaming turn for the same content" do
    capture_telemetry()
    steps = fn -> [FakeProvider.tool_step([@call]), FakeProvider.text_step("done")] end

    assert {:ok, "done"} = route(FakeProvider, steps.())
    assert_received {:telemetry, plain_measurements, plain_metadata}

    assert {:ok, "done"} = route(StreamingProvider, steps.())
    assert_received {:telemetry, streamed_measurements, streamed_metadata}

    assert Map.delete(streamed_measurements, :duration) ==
             Map.delete(plain_measurements, :duration)

    assert Map.delete(streamed_metadata, :provider) == Map.delete(plain_metadata, :provider)
  end

  test "a provider without converse_stream/4 never streams" do
    steps = [FakeProvider.text_step("fake reply")]

    assert {:ok, "fake reply"} = route(FakeProvider, steps)
    assert deltas() == []
  end

  test "without an interaction nothing streams" do
    FakeHub.configure(test_pid: self(), tools: [@tool], results: %{})
    steps = [FakeProvider.text_step("fake reply")]
    slots = slots(StreamingProvider, steps)

    assert {:ok, "fake reply"} = Router.route([], "hello", [route: :cloud], slots, FakeHub)
    assert deltas() == []
  end

  test "a stream that fails midway returns the error after the fragments already sent" do
    steps = [FakeProvider.text_step("fake reply")]

    assert {:error, :timeout} = route(StreamingProvider, steps, [], fail_after: 2)
    assert deltas() == ["fak", "e r"]
  end
end
