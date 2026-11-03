defmodule Mead.RouterNamedSlotsTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.{FakeHub, FakeInteraction, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}

  defmodule OptionsProvider do
    @moduledoc false
    @behaviour Mead.Provider

    # Reports the options it received, so a test can see what the router handed it.
    @impl true
    def complete(_messages, options) do
      send(Keyword.fetch!(options, :test_pid), {:provider_options, options})
      {:ok, %{text: "plain", usage: %{input_tokens: 1, output_tokens: 1}}}
    end

    @impl true
    def converse(_messages, _tools, options) do
      send(Keyword.fetch!(options, :test_pid), :conversed)
      {:error, :tools_unsupported}
    end

    # The path an interactive turn takes; it reports its tools and options like complete/2.
    @impl true
    def converse_stream(_messages, tools, options, _on_delta) do
      send(Keyword.fetch!(options, :test_pid), {:streamed, tools, options})

      {:ok,
       %{
         content: [%{type: :text, text: "plain"}],
         stop_reason: :end_turn,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  defp gemma(extra \\ []), do: {OptionsProvider, Keyword.merge([test_pid: self()], extra)}

  defp base_slots do
    reply = {:ok, %{text: "local reply", usage: FakeProvider.usage()}}
    [local: {FakeProvider, test_pid: self(), result: reply}]
  end

  defp hub, do: FakeHub.configure(test_pid: self(), tools: [@tool], results: %{})

  test "a forced named route reaches that slot's provider and is reported as the route" do
    handler = "named-slot-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mead, :router, :route],
      fn _event, _measurements, metadata, test_pid -> send(test_pid, {:routed, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    hub()
    slots = base_slots() ++ [gemma: gemma(tool_use: false)]

    assert Router.route([], "hello", [route: :gemma], slots, FakeHub) == {:ok, "plain"}
    assert_received {:routed, %{route: :gemma, route_source: :forced, provider: OptionsProvider}}
  end

  test "an empty or missing named slot fails without calling anything" do
    assert Router.route([], "hello", [route: :gemma], base_slots() ++ [gemma: nil]) ==
             {:error, {:slot_unavailable, :gemma}}

    assert Router.route([], "hello", [route: :gemma], base_slots()) ==
             {:error, {:slot_unavailable, :gemma}}

    refute_received {:provider_called, _messages}
  end

  test "tool_use: false makes a plain completion while tools are visible, and is not passed on" do
    hub()

    assert Router.route([], "hello", [route: :gemma], [gemma: gemma(tool_use: false)], FakeHub) ==
             {:ok, "plain"}

    assert_received {:provider_options, options}
    refute Keyword.has_key?(options, :tool_use)
    refute_received :conversed
    refute_received {:tools_requested, _options}
  end

  test "tool_use: false holds with effect tools and an interaction" do
    hub()
    interaction = {FakeInteraction, FakeInteraction.start([])}
    options = [route: :gemma, tools: :effect, interaction: interaction]

    assert Router.route([], "hello", options, [gemma: gemma(tool_use: false)], FakeHub) ==
             {:ok, "plain"}

    assert_received {:streamed, [], streamed_options}
    refute Keyword.has_key?(streamed_options, :tool_use)
    refute_received :conversed
  end

  test "without tool_use: false, visible tools go to the slot as before" do
    hub()

    assert Router.route([], "hello", [route: :gemma], [gemma: gemma()], FakeHub) ==
             {:error, :tools_unsupported}

    assert_received :conversed
  end

  test "a tool_use that is not a boolean is an invalid slot" do
    for value <- [nil, "false", 0] do
      assert Router.route([], "hello", [route: :gemma], gemma: gemma(tool_use: value)) ==
               {:error, :invalid_slot}
    end
  end

  test "a turn recorded on a named route continues on that slot" do
    hub()
    steps = [{:route, :gemma, :forced}]
    slots = base_slots() ++ [gemma: gemma(tool_use: false)]

    assert Router.replay([], "hello", steps, [route: :auto], slots, FakeHub) == {:ok, "plain"}
    assert_received {:provider_options, _options}
  end

  test "a recorded named route whose slot is gone fails as unavailable, with no fallback" do
    hub()
    steps = [{:route, :gemma, :forced}]

    assert Router.replay([], "hello", steps, [route: :auto], base_slots(), FakeHub) ==
             {:error, {:slot_unavailable, :gemma}}

    refute_received {:provider_called, _messages}
  end
end
