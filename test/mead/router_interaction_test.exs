defmodule Mead.RouterInteractionTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.{FakeHub, FakeInteraction, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}
  @call %{type: :tool_use, id: "call-1", name: "files__read_file", input: %{"path" => "/a"}}

  defp script(steps), do: start_supervised!({Agent, fn -> steps end}, id: make_ref())

  defp slots(steps) do
    [
      cloud: {FakeProvider, test_pid: self(), script: script(steps)},
      local: {FakeProvider, test_pid: self(), script: script([])}
    ]
  end

  defp hub(settings \\ []) do
    FakeHub.configure(
      Keyword.merge(
        [
          test_pid: self(),
          tools: [@tool],
          results: %{"files__read_file" => {:ok, %{content: "file body", is_error: false}}}
        ],
        settings
      )
    )
  end

  defp route(steps, answers, options \\ []) do
    context = FakeInteraction.start(answers)
    options = Keyword.merge([route: :cloud, interaction: {FakeInteraction, context}], options)
    Router.route([], "read /a", options, slots(steps), FakeHub)
  end

  # The model asks for `calls`, then answers with text once it has their results.
  defp tool_use_step(calls) do
    [
      FakeProvider.tool_step(for call <- calls, do: {call.id, call.name, call.input}),
      FakeProvider.text_step("fake reply")
    ]
  end

  defp second_conversation_messages do
    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, messages, _tools}
    messages
  end

  defp drain_statuses(statuses \\ []) do
    receive do
      {:tool_updated, update} -> drain_statuses(statuses ++ [update.status])
      {:request_permission, _request} -> drain_statuses(statuses ++ [:request_permission])
    after
      0 -> statuses
    end
  end

  test "an allowed call runs and the callbacks come in order" do
    hub()

    assert {:ok, "fake reply"} = route(tool_use_step([@call]), [:allow])

    assert drain_statuses() == [:pending, :request_permission, :in_progress, :completed]
    assert_received {:tool_called, "files__read_file", %{"path" => "/a"}, _options}
  end

  test "the request names the tool, the server, the class and the arguments" do
    hub()
    route(tool_use_step([@call]), [:allow])

    assert_received {:request_permission, request}

    assert request == %{
             tool_call_id: "call-1",
             tool: "read_file",
             server: "files",
             class: :read,
             arguments: %{"path" => "/a"}
           }
  end

  test "a rejected call never reaches the hub and the model gets an error result" do
    hub()

    assert {:ok, _text} = route(tool_use_step([@call]), [{:deny, :rejected}])

    refute_received {:tool_called, _name, _arguments, _options}
    assert drain_statuses() == [:pending, :request_permission, :failed]
    assert %{role: :user, content: [result]} = List.last(second_conversation_messages())
    assert result.is_error
    assert result.content == "The person rejected this tool call."
  end

  test "an expired call has its own text" do
    hub()
    route(tool_use_step([@call]), [{:deny, :expired}])

    assert %{content: [result]} = List.last(second_conversation_messages())

    assert result.content ==
             "The person did not answer in time, so this tool call was not run."
  end

  test "an unknown tool is reported failed without asking anyone" do
    hub()
    unknown = %{@call | name: "files__nope"}

    assert {:ok, _text} = route(tool_use_step([unknown]), [])

    refute_received {:request_permission, _request}
    assert drain_statuses() == [:pending, :failed]
  end

  test "two calls in one answer are asked one at a time, in order" do
    hub()
    second = %{@call | id: "call-2"}

    assert {:ok, _text} = route(tool_use_step([@call, second]), [:allow, {:deny, :rejected}])

    assert_received {:request_permission, %{tool_call_id: "call-1"}}
    assert_received {:tool_updated, %{tool_call_id: "call-1", status: :completed}}
    assert_received {:request_permission, %{tool_call_id: "call-2"}}
    assert_received {:tool_updated, %{tool_call_id: "call-2", status: :failed}}
  end

  test "a failing tool is reported failed after it ran" do
    hub(results: %{"files__read_file" => {:ok, %{content: "boom", is_error: true}}})
    route(tool_use_step([@call]), [:allow])

    assert drain_statuses() == [:pending, :request_permission, :in_progress, :failed]
  end

  test "the tool loop limit still applies" do
    hub()
    steps = List.duplicate(hd(tool_use_step([@call])), 9)

    assert {:error, :tool_loop_limit} = route(steps, [])
  end

  test "only a running call is cancellable" do
    hub()
    route(tool_use_step([@call]), [:allow])

    assert_received {:register_call, "call-1", _pid}

    cancellable =
      for status <- [:pending, :in_progress, :completed] do
        assert_received {:tool_updated, %{status: ^status, cancellable: flag}}
        flag
      end

    assert cancellable == [false, true, false]
  end

  test "killing the registered process cancels the call and the model is told" do
    hub(results: %{"files__read_file" => :block})
    context = FakeInteraction.start([:allow])
    options = [route: :cloud, interaction: {FakeInteraction, context}]
    configured_slots = slots(tool_use_step([@call]))
    test_pid = self()

    turn =
      Task.async(fn ->
        FakeHub.configure(
          test_pid: test_pid,
          tools: [@tool],
          results: %{"files__read_file" => :block}
        )

        Router.route([], "read /a", options, configured_slots, FakeHub)
      end)

    assert_receive {:register_call, "call-1", task_pid}, 2_000
    assert_receive {:tool_blocked, _blocked_pid}, 2_000
    Process.exit(task_pid, :kill)

    assert {:ok, "fake reply"} = Task.await(turn)
    refute Process.alive?(task_pid)

    assert_received {:tool_updated,
                     %{status: :failed, current_step: "cancelled", cancellable: false}}

    assert %{content: "The person cancelled this tool call.", is_error: true} =
             List.last(second_conversation_messages()).content |> hd()
  end

  test "a turn without an interaction makes no interaction calls" do
    hub()

    assert {:ok, "fake reply"} =
             Router.route([], "read /a", [route: :cloud], slots(tool_use_step([@call])), FakeHub)

    assert drain_statuses() == []
    assert_received {:tool_called, "files__read_file", _arguments, _options}
  end

  test "an invalid interaction is refused before the turn is recorded" do
    {:ok, session_id} = Mead.start_session(handler: Mead.Test.DeckHandler, turn_timeout: 1_000)
    on_exit(fn -> Mead.stop_session(session_id) end)

    for bad <- [:bad, {:bad, 1}, {String, 1}, nil] do
      assert {:error, :invalid_interaction} =
               Mead.submit_turn(session_id, "echo x", interaction: bad)
    end

    assert {:ok, []} = Mead.history(session_id)
  end
end
