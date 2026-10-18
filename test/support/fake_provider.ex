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

  def usage, do: %{input_tokens: 5, output_tokens: 3}
end
