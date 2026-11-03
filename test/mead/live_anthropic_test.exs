defmodule Mead.LiveAnthropicTest do
  # Calls the real Anthropic API with the key in ~/.config/anthropic/api.env, so it runs only on
  # request and spends a fraction of a cent: mix test --include live test/mead/live_anthropic_test.exs
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Provider.Anthropic
  alias Mead.Router
  alias Mead.Test.FakeHub

  @moduletag :live
  @moduletag timeout: 120_000

  @options [model: "claude-haiku-5-5", receive_timeout: 60_000]

  @tool %{
    name: "files__read_file",
    description: "Read a file from the notes folder and return its text.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }
  }

  defp user(text), do: [%{role: "user", content: text}]

  test "complete/2 answers with text and a counted usage" do
    assert {:ok, %{text: text, usage: usage}} =
             Anthropic.complete(user("Reply with exactly the word pong."), @options)

    assert text =~ ~r/pong/i
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0
  end

  test "converse/3 asks for a tool with an id, the tool's name and a map of input" do
    prompt = "Use the files__read_file tool to read notes.txt. Do not answer without it."

    assert {:ok, %{stop_reason: :tool_use, content: content}} =
             Anthropic.converse(user(prompt), [@tool], @options)

    assert [%{type: :tool_use, id: id, name: "files__read_file", input: input} | _rest] =
             for(%{type: :tool_use} = block <- content, do: block)

    assert is_binary(id) and id != ""
    assert %{"path" => path} = input
    assert path =~ "notes.txt"
  end

  test "converse_stream/4 streams deltas that add up to the final text" do
    test_pid = self()
    on_delta = fn delta -> send(test_pid, {:delta, delta}) end

    assert {:ok, %{stop_reason: :end_turn, content: content, usage: usage}} =
             Anthropic.converse_stream(
               user("Count from one to five in words, separated by spaces."),
               [],
               @options,
               on_delta
             )

    final_text = Enum.join(for %{type: :text, text: text} <- content, do: text)
    streamed = Enum.join(collect_deltas([]))

    assert final_text =~ ~r/one.*five/is
    assert streamed == final_text
    assert usage.output_tokens > 0
  end

  test "a key the API refuses is an http status, and the key never shows in the error" do
    key = "sk-ant-not-a-real-key-#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             Anthropic.complete(user("Reply with pong."), Keyword.put(@options, :api_key, key))

    assert reason == {:http_status, 401}
    refute inspect(reason) =~ key
  end

  test "a routed cloud turn runs the tool loop against the real API" do
    FakeHub.configure(
      test_pid: self(),
      tools: [@tool],
      results: %{
        "files__read_file" => {:ok, %{content: "The secret word is mango.", is_error: false}}
      }
    )

    slots = [local: nil, cloud: {Anthropic, @options}]
    prompt = "Use the files__read_file tool to read notes.txt, then tell me the secret word."

    assert {:ok, text} = Router.route([], prompt, [route: :cloud], slots, FakeHub)
    assert_received {:tool_called, "files__read_file", %{"path" => _path}, _options}
    assert text =~ ~r/mango/i
  end

  test "a routed tool loop sends its thinking back and the API changes none of it" do
    FakeHub.configure(
      test_pid: self(),
      tools: [@tool],
      results: %{
        "files__read_file" =>
          {:ok,
           %{content: "Order A: 17 boxes. Order B: 26 boxes. Order C: 9 boxes.", is_error: false}}
      }
    )

    test_pid = self()

    checkpoint = fn step ->
      send(test_pid, {:step, step})
      :ok
    end

    slots = [local: nil, cloud: {Anthropic, Keyword.put(@options, :block_binding, :drop_block)}]

    # Adaptive thinking skips a request this simple unless asked, and the test needs a block.
    prompt =
      "Before using any tool, think carefully about which file to read. Then use " <>
        "files__read_file to read orders.txt and report the total number of boxes and the " <>
        "average per order."

    log =
      capture_log(fn ->
        assert {:ok, text} =
                 Router.route([], prompt, [route: :cloud, checkpoint: checkpoint], slots, FakeHub)

        assert text =~ "52"
      end)

    answers = for {:step, {:provider_response, %{content: content}}} <- steps([]), do: content

    assert [first | [_ | _]] = answers

    assert Enum.any?(first, &match?(%{type: :thinking}, &1)),
           "the first answer held no thinking block, so the replay proved nothing"

    refute log =~ "replayed thinking block"
  end

  defp steps(collected) do
    receive do
      {:step, _step} = message -> steps([message | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp collect_deltas(deltas_reversed) do
    receive do
      {:delta, delta} -> collect_deltas([delta | deltas_reversed])
    after
      0 -> Enum.reverse(deltas_reversed)
    end
  end
end
