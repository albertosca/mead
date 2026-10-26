defmodule Mead.Test.FakeProvider do
  @moduledoc false

  # A provider that never touches the network. It reports what it was asked to the test process
  # named in `:test_pid` and answers with `:result`, so each test scripts exactly one outcome.

  @behaviour Mead.Provider

  @impl true
  def complete(messages, options) do
    send(Keyword.fetch!(options, :test_pid), {:provider_called, messages})

    Keyword.get(options, :result, {:ok, %{text: "fake reply", usage: usage()}})
  end

  # Scripted conversation: the next step comes from the Agent given as `:script`, so a test can
  # play a model that asks for a tool and then answers. A step is the whole return value.
  @impl true
  def converse(messages, tools, options) do
    send(Keyword.fetch!(options, :test_pid), {:provider_conversed, messages, tools})

    Agent.get_and_update(Keyword.fetch!(options, :script), fn [next | rest] -> {next, rest} end)
  end

  def text_step(text, usage \\ usage()) do
    {:ok, %{content: [%{type: :text, text: text}], stop_reason: :end_turn, usage: usage}}
  end

  def tool_step(tool_uses, usage \\ usage()) do
    blocks =
      for {id, name, input} <- tool_uses, do: %{type: :tool_use, id: id, name: name, input: input}

    {:ok, %{content: blocks, stop_reason: :tool_use, usage: usage}}
  end

  # A model that says something before it asks for the tool.
  def tool_step_with_text(text, tool_uses, usage \\ usage()) do
    {:ok, %{content: content} = step} = tool_step(tool_uses, usage)
    {:ok, %{step | content: [%{type: :text, text: text} | content]}}
  end

  def usage, do: %{input_tokens: 5, output_tokens: 3}
end
