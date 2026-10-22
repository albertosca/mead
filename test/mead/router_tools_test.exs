defmodule Mead.RouterToolsTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Session.Turn
  alias Mead.Test.{FakeHub, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}

  defmodule CompleteOnlyProvider do
    @moduledoc false
    @behaviour Mead.Provider

    @impl true
    def complete(_messages, options) do
      send(Keyword.fetch!(options, :test_pid), :complete_called)
      {:ok, %{text: "plain reply", usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  defp script(steps), do: start_supervised!({Agent, fn -> steps end}, id: make_ref())

  defp slots(steps) do
    [
      cloud: {FakeProvider, test_pid: self(), script: script(steps)},
      local: {FakeProvider, test_pid: self(), script: script([])}
    ]
  end

  defp hub(results \\ %{}, tools \\ [@tool]) do
    FakeHub.configure(test_pid: self(), tools: tools, results: results)
  end

  defp route(steps, options \\ [route: :cloud], history \\ []) do
    Router.route(history, "read /a", options, slots(steps), FakeHub)
  end

  defp capture_event(function) do
    test_pid = self()
    handler_id = "router-tools-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:mead, :router, :route],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:route_event, measurements, metadata})
      end,
      nil
    )

    try do
      function.()
    after
      :telemetry.detach(handler_id)
    end
  end

  test "without any visible tool the turn takes the plain path" do
    hub(%{}, [])

    assert route([]) == {:ok, "fake reply"}
    assert_received {:provider_called, _messages}
    refute_received {:provider_conversed, _messages, _tools}
  end

  test "a provider that cannot converse is never given tools" do
    hub()
    slots = [cloud: {CompleteOnlyProvider, test_pid: self()}]

    assert Router.route([], "hi", [route: :cloud], slots, FakeHub) == {:ok, "plain reply"}
    assert_received :complete_called
  end

  test "the local route never gets tools" do
    hub()

    assert Router.route([], "list tasks", [route: :local], slots([]), FakeHub) ==
             {:ok, "fake reply"}

    refute_received {:provider_conversed, _messages, _tools}
    refute_received {:tools_requested, _options}
  end

  test "the hub is asked for the tools with the turn options, including the session id and the opt-in" do
    hub()

    route([FakeProvider.text_step("done")],
      route: :cloud,
      tools: :effect,
      session_id: "session-1"
    )

    assert_received {:tools_requested, options}
    assert Keyword.get(options, :tools) == :effect
    assert Keyword.get(options, :session_id) == "session-1"
  end

  test "one tool call and then the answer" do
    hub(%{"files__read_file" => {:ok, %{content: "file contents", is_error: false}}})

    steps = [
      FakeProvider.tool_step([{"toolu_1", "files__read_file", %{"path" => "/a"}}]),
      FakeProvider.text_step("The file says: file contents")
    ]

    assert route(steps) == {:ok, "The file says: file contents"}

    assert_received {:provider_conversed, first_messages, [@tool]}
    assert first_messages == [%{role: :user, content: "read /a"}]

    assert_received {:tool_called, "files__read_file", %{"path" => "/a"}, _options}

    assert_received {:provider_conversed, second_messages, [@tool]}

    assert second_messages == [
             %{role: :user, content: "read /a"},
             %{
               role: :assistant,
               content: [
                 %{
                   type: :tool_use,
                   id: "toolu_1",
                   name: "files__read_file",
                   input: %{"path" => "/a"}
                 }
               ]
             },
             %{
               role: :user,
               content: [
                 %{
                   type: :tool_result,
                   tool_use_id: "toolu_1",
                   content: "file contents",
                   is_error: false
                 }
               ]
             }
           ]
  end

  test "several tool calls in one step are all answered, in order, in one user message" do
    hub(%{
      "files__read_file" => {:ok, %{content: "one", is_error: false}}
    })

    steps = [
      FakeProvider.tool_step([
        {"t1", "files__read_file", %{"path" => "/1"}},
        {"t2", "files__read_file", %{"path" => "/2"}}
      ]),
      FakeProvider.text_step("both read")
    ]

    assert route(steps) == {:ok, "both read"}

    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, second, _tools}

    assert [%{content: [%{tool_use_id: "t1"}, %{tool_use_id: "t2"}]}] = Enum.take(second, -1)
  end

  test "a tool that reports an error goes back to the model as an error result" do
    hub(%{"files__read_file" => {:ok, %{content: "ENOENT", is_error: true}}})

    steps = [
      FakeProvider.tool_step([{"toolu_1", "files__read_file", %{}}]),
      FakeProvider.text_step("It does not exist.")
    ]

    assert route(steps) == {:ok, "It does not exist."}

    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, second, _tools}
    assert %{content: [%{content: "ENOENT", is_error: true}]} = List.last(second)
  end

  test "a denied or unknown tool goes back as an error result and the loop continues" do
    hub(%{"files__write_file" => {:error, :not_allowed}})

    steps = [
      FakeProvider.tool_step([
        {"t1", "files__write_file", %{}},
        {"t2", "ghost__tool", %{}}
      ]),
      FakeProvider.text_step("I could not do that.")
    ]

    assert route(steps) == {:ok, "I could not do that."}

    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, second, _tools}

    assert %{content: [first, second_result]} = List.last(second)
    assert first.is_error and first.content =~ "not allowed"
    assert second_result.is_error and second_result.content =~ "unknown tool"
  end

  test "an error tuple the router does not know is described without crashing" do
    hub(%{"files__read_file" => {:error, {:rpc_error, -32_602, "bad"}}})

    steps = [
      FakeProvider.tool_step([{"t1", "files__read_file", %{}}]),
      FakeProvider.text_step("ok")
    ]

    assert route(steps) == {:ok, "ok"}
    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, second, _tools}
    assert %{content: [%{is_error: true, content: content}]} = List.last(second)
    assert is_binary(content) and content != ""
  end

  test "the loop stops after eight provider calls" do
    hub(%{"files__read_file" => {:ok, %{content: "again", is_error: false}}})
    endless = List.duplicate(FakeProvider.tool_step([{"t", "files__read_file", %{}}]), 20)

    assert route(endless) == {:error, :tool_loop_limit}

    for _call <- 1..8, do: assert_received({:provider_conversed, _messages, _tools})
    refute_received {:provider_conversed, _messages, _tools}
  end

  test "usage is summed over every provider call, and the tool calls are counted" do
    hub(%{"files__read_file" => {:ok, %{content: "x", is_error: false}}})
    usage = fn input, output -> %{input_tokens: input, output_tokens: output} end

    steps = [
      FakeProvider.tool_step(
        [{"t1", "files__read_file", %{}}, {"t2", "files__read_file", %{}}],
        usage.(10, 2)
      ),
      FakeProvider.text_step("done", usage.(20, 5))
    ]

    capture_event(fn -> assert route(steps) == {:ok, "done"} end)

    assert_received {:route_event, measurements, metadata}
    assert measurements.input_tokens == 30
    assert measurements.output_tokens == 7
    assert measurements.tool_calls == 2
    assert metadata.status == :ok
    assert metadata.route == :cloud
  end

  test "a plain turn reports zero tool calls" do
    hub(%{}, [])

    capture_event(fn -> route([]) end)

    assert_received {:route_event, measurements, _metadata}
    assert measurements.tool_calls == 0
  end

  test "a provider that fails mid-loop reports the tokens it already used, as a failed turn" do
    hub(%{"files__read_file" => {:ok, %{content: "x", is_error: false}}})

    steps = [
      FakeProvider.tool_step([{"t1", "files__read_file", %{}}], %{
        input_tokens: 10,
        output_tokens: 2
      }),
      {:error, {:http_status, 529}}
    ]

    capture_event(fn -> assert route(steps) == {:error, {:http_status, 529}} end)

    assert_received {:route_event, measurements, metadata}
    assert measurements.input_tokens == 10
    assert measurements.output_tokens == 2
    assert measurements.tool_calls == 1
    assert metadata.status == :error
  end

  test "a tool_use stop without any tool_use block is malformed, not an empty tool message" do
    hub()

    step =
      {:ok,
       %{
         content: [%{type: :text, text: "hmm"}],
         stop_reason: :tool_use,
         usage: FakeProvider.usage()
       }}

    assert route([step]) == {:error, :malformed_response}
  end

  test "an answer with no text is malformed" do
    hub()
    step = {:ok, %{content: [], stop_reason: :end_turn, usage: FakeProvider.usage()}}

    assert route([step]) == {:error, :malformed_response}
  end

  test "earlier completed turns are replayed ahead of the tool exchange" do
    hub()
    history = [%Turn{Turn.start("one") | status: :ok, output: "uno"}]

    route([FakeProvider.text_step("done")], [route: :cloud], history)

    assert_received {:provider_conversed, messages, _tools}

    assert messages == [
             %{role: :user, content: "one"},
             %{role: :assistant, content: "uno"},
             %{role: :user, content: "read /a"}
           ]
  end

  test "input that is not text still fails before any tool is offered" do
    hub()

    assert Router.route([], {:not, :text}, [route: :cloud], slots([]), FakeHub) ==
             {:error, :unsupported_input}

    refute_received {:tools_requested, _options}
  end
end
