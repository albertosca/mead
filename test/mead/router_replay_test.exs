defmodule Mead.RouterReplayTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.{FakeHub, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}
  @in_doubt "This call was already running when the server stopped. It may or may not have taken effect; check before calling it again."

  defp script(steps), do: start_supervised!({Agent, fn -> steps end}, id: make_ref())

  defp slots(steps), do: [cloud: {FakeProvider, test_pid: self(), script: script(steps)}]

  defp hub(results \\ %{"files__read_file" => {:ok, %{content: "data", is_error: false}}}) do
    FakeHub.configure(test_pid: self(), tools: [@tool], results: results)
  end

  defp recording do
    test_pid = self()

    fn step ->
      send(test_pid, {:step, step})
      :ok
    end
  end

  defp options(checkpoint \\ recording()), do: [route: :cloud, checkpoint: checkpoint]

  defp recorded_steps(steps \\ []) do
    receive do
      {:step, step} -> recorded_steps([step | steps])
    after
      0 -> Enum.reverse(steps)
    end
  end

  defp response({:ok, %{content: content, stop_reason: stop_reason, usage: usage}}),
    do: {:provider_response, %{content: content, stop_reason: stop_reason, usage: usage}}

  defp capture_event(function) do
    test_pid = self()
    handler_id = "router-replay-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:mead, :router, :route],
      fn _event, measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:route_event, measurements})
      end,
      nil
    )

    try do
      function.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp live_tool_turn do
    hub()
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{"path" => "/a"}}])
    text_step = FakeProvider.text_step("done")

    assert Router.route([], "read /a", options(), slots([tool_step, text_step]), FakeHub) ==
             {:ok, "done"}

    {tool_step, text_step, recorded_steps()}
  end

  test "a live tool turn records its route, every response, and every call" do
    {tool_step, text_step, steps} = live_tool_turn()

    assert [
             {:route, :cloud, :forced},
             response(tool_step),
             {:tool_started, "t1", :read},
             {:tool_result, "t1", %{type: :tool_result, tool_use_id: "t1", content: "data"}},
             response(text_step)
           ] == update_in_result(steps)
  end

  # The recorded result carries is_error too; compare it by its main fields.
  defp update_in_result(steps) do
    Enum.map(steps, fn
      {:tool_result, id, result} -> {:tool_result, id, Map.drop(result, [:is_error])}
      step -> step
    end)
  end

  test "replaying every step calls neither the model nor the tool" do
    {_tool_step, _text_step, steps} = live_tool_turn()
    flush_calls()

    assert Router.replay([], "read /a", steps, options(), slots([]), FakeHub) == {:ok, "done"}
    refute_received {:provider_conversed, _messages, _tools}
    refute_received {:tool_called, _name, _arguments, _options}
    assert recorded_steps() == []
  end

  defp flush_calls do
    receive do
      {kind, _messages, _tools} when kind in [:provider_conversed] -> flush_calls()
      {:tool_called, _name, _arguments, _options} -> flush_calls()
      {:tools_requested, _options} -> flush_calls()
    after
      0 -> :ok
    end
  end

  test "an effect call in doubt is reported to the model and never runs again" do
    hub()
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])
    steps = [{:route, :cloud, :forced}, response(tool_step), {:tool_started, "t1", :effect}]

    assert Router.replay(
             [],
             "read /a",
             steps,
             options(),
             slots([FakeProvider.text_step("ok")]),
             FakeHub
           ) ==
             {:ok, "ok"}

    refute_received {:tool_called, _name, _arguments, _options}
    assert_received {:provider_conversed, messages, _tools}
    assert %{role: :user, content: [%{content: @in_doubt, is_error: true}]} = List.last(messages)

    assert [
             {:tool_result, "t1", %{tool_use_id: "t1", content: @in_doubt, is_error: true}},
             {:provider_response, %{stop_reason: :end_turn}}
           ] = recorded_steps()
  end

  test "a read call in doubt runs again without being recorded as started twice" do
    hub()
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])
    steps = [{:route, :cloud, :forced}, response(tool_step), {:tool_started, "t1", :read}]

    assert Router.replay(
             [],
             "read /a",
             steps,
             options(),
             slots([FakeProvider.text_step("ok")]),
             FakeHub
           ) ==
             {:ok, "ok"}

    assert_received {:tool_called, "files__read_file", _arguments, _options}
    refute_received {:tool_called, _name, _arguments, _options}

    assert [{:tool_result, "t1", %{content: "data"}}, {:provider_response, _response}] =
             recorded_steps()
  end

  # The servers that come back after a restart may offer other tools: the continued turn offers
  # the model what is there now, and a call in doubt to a tool that is gone fails plainly.
  test "a continued turn whose tool is gone after the restart tells the model and goes on" do
    other_tool = %{name: "notes__list", description: "List", input_schema: %{"type" => "object"}}
    FakeHub.configure(test_pid: self(), tools: [other_tool], results: %{})
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])
    steps = [{:route, :cloud, :forced}, response(tool_step), {:tool_started, "t1", :read}]

    assert Router.replay(
             [],
             "read /a",
             steps,
             options(),
             slots([FakeProvider.text_step("ok")]),
             FakeHub
           ) == {:ok, "ok"}

    assert_received {:provider_conversed, messages, [%{name: "notes__list"}]}

    assert %{content: [%{content: "The tool call failed: unknown tool.", is_error: true}]} =
             List.last(messages)
  end

  # With no tool left the turn cannot go on as a tool loop: the answer is asked for again
  # without tools, and nothing recorded runs again.
  test "a continued turn with no tools left asks for its answer again and runs nothing" do
    FakeHub.configure(test_pid: self(), tools: [], results: %{})
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])
    steps = [{:route, :cloud, :forced}, response(tool_step), {:tool_started, "t1", :effect}]
    slots = [cloud: {FakeProvider, test_pid: self()}]

    assert Router.replay([], "read /a", steps, options(), slots, FakeHub) == {:ok, "fake reply"}
    refute_received {:tool_called, _name, _arguments, _options}
    refute_received {:provider_conversed, _messages, _tools}
  end

  test "calls that reuse an id are replayed by position" do
    hub()
    first = FakeProvider.tool_step([{"call_1", "files__read_file", %{"n" => 1}}])
    second = FakeProvider.tool_step([{"call_1", "files__read_file", %{"n" => 2}}])
    first_result = %{type: :tool_result, tool_use_id: "call_1", content: "first", is_error: false}

    steps = [
      {:route, :cloud, :forced},
      response(first),
      {:tool_started, "call_1", :read},
      {:tool_result, "call_1", first_result},
      response(second),
      {:tool_started, "call_1", :read}
    ]

    assert Router.replay(
             [],
             "read",
             steps,
             options(),
             slots([FakeProvider.text_step("end")]),
             FakeHub
           ) ==
             {:ok, "end"}

    assert_received {:tool_called, "files__read_file", %{"n" => 2}, _options}
    refute_received {:tool_called, _name, _arguments, _options}
    assert_received {:provider_conversed, messages, _tools}

    assert [%{content: "first"}, %{content: "data"}] =
             for(
               %{role: :user, content: [%{type: :tool_result} = result]} <- messages,
               do: result
             )
  end

  test "a checkpoint that cannot be written ends the turn before the tool runs" do
    hub()
    test_pid = self()

    checkpoint = fn
      {:tool_started, _id, _class} ->
        {:error, :disk}

      step ->
        send(test_pid, {:step, step})
        :ok
    end

    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])

    assert Router.route([], "read /a", options(checkpoint), slots([tool_step]), FakeHub) ==
             {:error, {:checkpoint_failed, :disk}}

    refute_received {:tool_called, _name, _arguments, _options}
  end

  test "a replayed turn counts the tokens of every call once" do
    {_tool_step, _text_step, steps} = live_tool_turn()

    capture_event(fn ->
      assert Router.replay([], "read /a", steps, options(), slots([]), FakeHub) == {:ok, "done"}
    end)

    assert_received {:route_event, %{input_tokens: 10, output_tokens: 6, tool_calls: 1}}
  end

  test "a tool-less turn records its one answer and replays it" do
    FakeHub.configure(test_pid: self(), tools: [], results: %{})
    slots = [cloud: {FakeProvider, test_pid: self()}]

    assert Router.route([], "hello", options(), slots, FakeHub) == {:ok, "fake reply"}
    assert_received {:provider_called, _messages}

    assert [
             {:route, :cloud, :forced},
             {:provider_response,
              %{
                content: [%{type: :text, text: "fake reply"}],
                stop_reason: :end_turn,
                usage: _usage
              }}
           ] = steps = recorded_steps()

    assert Router.replay([], "hello", steps, options(), slots, FakeHub) == {:ok, "fake reply"}
    refute_received {:provider_called, _messages}
  end

  test "a recorded route is used instead of classifying again" do
    FakeHub.configure(test_pid: self(), tools: [], results: %{})

    slots = [
      local:
        {FakeProvider,
         test_pid: self(), result: {:ok, %{text: "local", usage: FakeProvider.usage()}}}
    ]

    assert Router.replay(
             [],
             "hello",
             [{:route, :local, :classified}],
             [route: :auto, checkpoint: recording()],
             slots,
             FakeHub
           ) ==
             {:ok, "local"}

    assert [{:provider_response, _response}] = recorded_steps()
  end

  test "a continued turn waits for the tool servers first, a fresh one does not" do
    FakeHub.configure(test_pid: self(), tools: [], results: %{})
    slots = [cloud: {FakeProvider, test_pid: self()}]

    assert Router.route([], "hello", options(), slots, FakeHub) == {:ok, "fake reply"}
    refute_received {:hub_awaited, _timeout}

    assert Router.replay([], "hello", [{:route, :cloud, :forced}], options(), slots, FakeHub) ==
             {:ok, "fake reply"}

    assert_received {:hub_awaited, 10_000}
  end

  test "steps that do not fit are dropped and the turn goes on live" do
    hub()
    steps = [{:route, :cloud, :forced}, {:tool_result, "t9", %{}}, :garbage]

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Router.replay(
          [],
          "read",
          steps,
          options(),
          slots([FakeProvider.text_step("live")]),
          FakeHub
        )
      end)

    assert result == {:ok, "live"}
    assert_received {:provider_conversed, _messages, _tools}
    assert log =~ "dropped 2 recorded steps that do not fit"
  end

  test "a log without a readable route drops every step with a warning" do
    hub()

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Router.replay(
          [],
          "read",
          [:garbage],
          options(),
          slots([FakeProvider.text_step("live")]),
          FakeHub
        )
      end)

    assert result == {:ok, "live"}
    assert log =~ "dropped 1 recorded step that does not fit"
  end

  test "without a checkpoint nothing is recorded" do
    hub()
    tool_step = FakeProvider.tool_step([{"t1", "files__read_file", %{}}])

    assert Router.route(
             [],
             "read /a",
             [route: :cloud],
             slots([tool_step, FakeProvider.text_step("ok")]),
             FakeHub
           ) ==
             {:ok, "ok"}

    assert recorded_steps() == []
  end

  describe "thinking blocks" do
    @recorded_thinking %{type: :thinking, thinking: "", signature: "signature-recorded"}
    @live_thinking %{type: :thinking, thinking: "private reasoning", signature: "signature-live"}

    defp with_thinking({:ok, %{content: content} = answer}, blocks),
      do: {:ok, %{answer | content: blocks ++ content}}

    test "a live tool loop sends the answer back with its thinking, and keeps it out of the output" do
      hub()

      tool_step =
        [{"t1", "files__read_file", %{"path" => "/a"}}]
        |> FakeProvider.tool_step()
        |> with_thinking([@live_thinking, %{type: :redacted_thinking, data: "opaque"}])

      text_step = with_thinking(FakeProvider.text_step("done"), [@live_thinking])

      assert Router.route([], "read /a", options(), slots([tool_step, text_step]), FakeHub) ==
               {:ok, "done"}

      assert_received {:provider_conversed, _first, _tools}
      assert_received {:provider_conversed, second, _tools}

      assert %{
               role: :assistant,
               content: [@live_thinking, %{type: :redacted_thinking, data: "opaque"} | _rest]
             } = Enum.at(second, -2)
    end

    test "a resumed turn sends a recorded answer without its thinking, and a live one with it" do
      hub()

      recorded_step =
        [{"t1", "files__read_file", %{"path" => "/a"}}]
        |> FakeProvider.tool_step()
        |> with_thinking([@recorded_thinking, %{type: :redacted_thinking, data: "old"}])

      live_step =
        [{"t2", "files__read_file", %{"path" => "/b"}}]
        |> FakeProvider.tool_step()
        |> with_thinking([@live_thinking])

      steps = [{:route, :cloud, :forced}, response(recorded_step)]

      assert Router.replay(
               [],
               "read /a",
               steps,
               options(),
               slots([live_step, FakeProvider.text_step("done")]),
               FakeHub
             ) == {:ok, "done"}

      assert_received {:provider_conversed, _after_replay, _tools}
      assert_received {:provider_conversed, messages, _tools}

      assert [recorded_content, live_content] =
               for(%{role: :assistant, content: content} <- messages, do: content)

      assert [%{type: :tool_use, id: "t1"}] = recorded_content
      assert [@live_thinking, %{type: :tool_use, id: "t2"}] = live_content

      assert Enum.any?(recorded_steps(), fn
               {:provider_response, %{content: [@live_thinking | _rest]}} -> true
               _other -> false
             end)
    end
  end
end
