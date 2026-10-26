defmodule Mead.Test.StreamingProvider do
  @moduledoc false

  # `Mead.Test.FakeProvider` that can also stream: `converse_stream/4` takes the same scripted step,
  # hands every text block to `on_delta` in `:fragment_size` pieces, then returns the step. With
  # `:fail_after` set to a count it stops after that many fragments and returns `{:error, :timeout}`.

  @behaviour Mead.Provider

  alias Mead.Test.FakeProvider

  @impl true
  defdelegate complete(messages, options), to: FakeProvider

  @impl true
  defdelegate converse(messages, tools, options), to: FakeProvider

  @impl true
  def converse_stream(messages, tools, options, on_delta) do
    step = FakeProvider.converse(messages, tools, options)
    fragment_size = Keyword.get(options, :fragment_size, 3)
    fail_after = Keyword.get(options, :fail_after)

    fragments =
      case step do
        {:ok, %{content: content}} ->
          for %{type: :text, text: text} <- content,
              fragment <- pieces(text, fragment_size),
              do: fragment

        _error ->
          []
      end

    case fail_after do
      nil ->
        Enum.each(fragments, on_delta)
        step

      count ->
        fragments |> Enum.take(count) |> Enum.each(on_delta)
        {:error, :timeout}
    end
  end

  defp pieces("", _size), do: []

  defp pieces(text, size) do
    {piece, rest} = String.split_at(text, size)
    [piece | pieces(rest, size)]
  end
end
