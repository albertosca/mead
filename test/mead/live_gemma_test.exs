defmodule Mead.LiveGemmaTest do
  # Needs `ollama serve` with gemma2:2b pulled, so it runs only on request:
  # mix test --include live test/mead/live_gemma_test.exs
  use ExUnit.Case, async: true

  alias Mead.Router
  alias Mead.Test.FakeHub

  @moduletag :live
  @moduletag timeout: 300_000

  @tool %{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}
  @gemma [model: "gemma2:2b", keep_alive: "5m", receive_timeout: 180_000]

  setup do
    FakeHub.configure(test_pid: self(), tools: [@tool], results: %{})
    :ok
  end

  test "a Gemma slot with tool_use: false answers while a tool is visible" do
    slots = [gemma: {Mead.Provider.Ollama, @gemma ++ [tool_use: false]}]

    assert {:ok, text} =
             Router.route(
               [],
               "Reply with exactly the word pong.",
               [route: :gemma],
               slots,
               FakeHub
             )

    assert text =~ ~r/pong/i
  end

  test "without tool_use: false the same slot fails, because Gemma 2 has no tool support" do
    slots = [gemma: {Mead.Provider.Ollama, @gemma}]

    assert Router.route([], "Reply with pong.", [route: :gemma], slots, FakeHub) ==
             {:error, :tools_unsupported}
  end
end
