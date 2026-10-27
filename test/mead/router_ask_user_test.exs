defmodule Mead.RouterAskUserTest do
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Router.AskUser
  alias Mead.Test.{FakeHub, FakeInteraction, FakeProvider}

  @moduletag :capture_log

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}
  @options [%{"id" => "a", "label" => "Alpha"}, %{"id" => "b", "label" => "Beta"}]
  @question %{"prompt" => "Which one?", "options" => @options}

  defp script(steps), do: start_supervised!({Agent, fn -> steps end}, id: make_ref())

  defp slots(steps) do
    [
      cloud: {FakeProvider, test_pid: self(), script: script(steps)},
      local: {FakeProvider, test_pid: self(), script: script([])}
    ]
  end

  defp ask_steps(input) do
    [
      FakeProvider.tool_step([{"ask-1", "ask_user", input}]),
      FakeProvider.text_step("fake reply")
    ]
  end

  defp route(steps, answers, tools \\ [@tool], options \\ []) do
    FakeHub.configure(test_pid: self(), tools: tools, results: %{})
    context = FakeInteraction.start(answers)
    options = Keyword.merge([route: :cloud, interaction: {FakeInteraction, context}], options)
    Router.route([], "decide", options, slots(steps), FakeHub)
  end

  defp result_after_ask do
    assert_received {:provider_conversed, _first, _tools}
    assert_received {:provider_conversed, messages, _tools}
    %{role: :user, content: [result]} = List.last(messages)
    result
  end

  describe "validate/1" do
    test "accepts a well-formed question and ignores extra fields" do
      input = Map.merge(@question, %{"extra" => 1})

      assert {:ok, %{prompt: "Which one?", options: [%{id: "a", label: "Alpha"}, _second]}} =
               AskUser.validate(input)
    end

    test "allow_free_text defaults to false and accepts only a boolean" do
      assert {:ok, %{allow_free_text: false}} = AskUser.validate(@question)

      assert {:ok, %{allow_free_text: true}} =
               AskUser.validate(Map.put(@question, "allow_free_text", true))

      assert {:error, reason} = AskUser.validate(Map.put(@question, "allow_free_text", "yes"))
      assert reason =~ "allow_free_text"
    end

    @invalid [
      {"one option", %{"prompt" => "?", "options" => [%{"id" => "a", "label" => "A"}]}},
      {"seven options",
       %{
         "prompt" => "?",
         "options" => for(number <- 1..7, do: %{"id" => "#{number}", "label" => "L#{number}"})
       }},
      {"duplicate ids",
       %{
         "prompt" => "?",
         "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "a", "label" => "B"}]
       }},
      {"empty label",
       %{
         "prompt" => "?",
         "options" => [%{"id" => "a", "label" => " "}, %{"id" => "b", "label" => "B"}]
       }},
      {"empty id",
       %{
         "prompt" => "?",
         "options" => [%{"id" => "", "label" => "A"}, %{"id" => "b", "label" => "B"}]
       }},
      {"label over 80 characters",
       %{
         "prompt" => "?",
         "options" => [
           %{"id" => "a", "label" => String.duplicate("x", 81)},
           %{"id" => "b", "label" => "B"}
         ]
       }},
      {"prompt not a string", %{"prompt" => 1, "options" => @options}},
      {"prompt over 500 characters",
       %{"prompt" => String.duplicate("x", 501), "options" => @options}},
      {"blank prompt", %{"prompt" => "  ", "options" => @options}},
      {"options not a list", %{"prompt" => "?", "options" => "a,b"}},
      {"option not a map", %{"prompt" => "?", "options" => ["a", "b"]}},
      {"missing options", %{"prompt" => "?"}},
      {"not a map", "prompt"}
    ]

    for {name, input} <- @invalid do
      test "refuses #{name}" do
        assert {:error, reason} = AskUser.validate(unquote(Macro.escape(input)))
        assert is_binary(reason)
      end
    end
  end

  describe "the tool in a turn" do
    test "is offered with an interaction and a tool, and the model sees it" do
      assert {:ok, "fake reply"} = route(ask_steps(@question), [{:ok, "a"}])

      assert_received {:provider_conversed, _messages, tools}
      assert "ask_user" in Enum.map(tools, & &1.name)
    end

    test "is absent without an interaction" do
      FakeHub.configure(test_pid: self(), tools: [@tool], results: %{})
      steps = [FakeProvider.text_step("fake reply")]
      assert {:ok, _text} = Router.route([], "hi", [route: :cloud], slots(steps), FakeHub)

      assert_received {:provider_conversed, _messages, tools}
      refute "ask_user" in Enum.map(tools, & &1.name)
    end

    test "is absent when the turn has no other tool" do
      assert {:ok, _text} = route([FakeProvider.text_step("fake reply")], [], [])

      assert_received {:provider_called, _messages}
      refute_received {:provider_conversed, _messages, _tools}
    end

    test "is absent for a provider without converse/3" do
      defmodule CompleteOnlyProvider do
        @behaviour Mead.Provider

        @impl true
        def complete(messages, options) do
          send(Keyword.fetch!(options, :test_pid), {:provider_called, messages})
          {:ok, %{text: "plain reply", usage: %{input_tokens: 1, output_tokens: 1}}}
        end
      end

      FakeHub.configure(test_pid: self(), tools: [@tool], results: %{})
      context = FakeInteraction.start([])

      slots = [
        cloud: {CompleteOnlyProvider, test_pid: self()},
        local: {CompleteOnlyProvider, test_pid: self()}
      ]

      options = [route: :cloud, interaction: {FakeInteraction, context}]
      assert {:ok, "plain reply"} = Router.route([], "hi", options, slots, FakeHub)
      refute_received {:tools_requested, _options}
    end

    test "the chosen label reaches the model and the interaction sees the question" do
      assert {:ok, "fake reply"} = route(ask_steps(@question), [{:ok, "b"}])

      assert_received {:ask_choice,
                       %{tool_call_id: "ask-1", prompt: "Which one?", options: options}}

      assert options == [%{id: "a", label: "Alpha"}, %{id: "b", label: "Beta"}]
      assert %{content: "The person chose: Beta", is_error: false} = result_after_ask()
    end

    test "a free text answer reaches the model when the question allowed it" do
      input = Map.put(@question, "allow_free_text", true)
      assert {:ok, "fake reply"} = route(ask_steps(input), [{:ok, {:text, "neither, call me"}}])

      assert_received {:ask_choice, %{allow_free_text: true}}

      assert %{content: "The person answered: neither, call me", is_error: false} =
               result_after_ask()
    end

    test "a free text answer to a question that did not allow it is an error result" do
      route(ask_steps(@question), [{:ok, {:text, "sneaky"}}])
      assert_received {:ask_choice, %{allow_free_text: false}}
      assert %{is_error: true} = result_after_ask()
    end

    test "an expired question is an error result" do
      route(ask_steps(@question), [{:error, :expired}])
      assert %{content: "The person did not choose in time.", is_error: true} = result_after_ask()
    end

    test "nobody to ask is an error result" do
      route(ask_steps(@question), [])
      assert %{content: "The person could not be asked.", is_error: true} = result_after_ask()
    end

    test "an answer outside the offered options is an error result" do
      route(ask_steps(@question), [{:ok, "zzz"}])
      assert %{is_error: true} = result_after_ask()
    end

    test "invalid arguments never reach the interaction" do
      route(ask_steps(%{"prompt" => "?", "options" => []}), [{:ok, "a"}])

      refute_received {:ask_choice, _choice}
      assert %{content: content, is_error: true} = result_after_ask()
      assert content =~ "ask_user arguments are invalid"
    end

    test "is not gated by permission and is never run by the hub" do
      route(ask_steps(@question), [{:ok, "a"}])

      refute_received {:request_permission, _request}
      refute_received {:tool_called, "ask_user", _arguments, _options}
    end
  end
end
