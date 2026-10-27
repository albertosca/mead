defmodule Mead.Deck.Details do
  @moduledoc """
  The details of a permission request, built from the arguments the model gave the tool.

  `lines/1` is the original form, one `key: value` string per argument. `items/1` is the same
  content as objects: the raw `key` and `value`, a `label` (the key spoken as words) and, when the
  value is a snake_case identifier, a `display` (the identifier spoken as words). A deck that only
  knows the lines keeps working, and a deck that knows the items shows words instead of protocol
  names. Every value is cut at #{2_000} characters and none of it is ever logged.
  """

  @maximum_characters 2_000
  @identifier ~r/\A[a-z][a-z0-9]*(_[a-z0-9]+)+\z/

  @spec lines(term()) :: [String.t()]
  def lines(arguments) when is_map(arguments) do
    arguments
    |> pairs()
    |> Enum.map(fn {key, value} -> key <> ": " <> value end)
  end

  def lines(arguments), do: ["arguments: " <> truncate(render(arguments))]

  @spec items(term()) :: [map()]
  def items(arguments) when is_map(arguments) do
    arguments
    |> pairs()
    |> Enum.map(fn {key, value} ->
      %{"key" => key, "value" => value, "label" => humanize(key)}
      |> put_display(value)
    end)
  end

  def items(arguments) do
    value = truncate(render(arguments))
    [%{"key" => "arguments", "value" => value, "label" => "Arguments"}]
  end

  defp pairs(arguments) do
    arguments
    |> Enum.map(fn {key, value} -> {render(key), truncate(render(value))} end)
    |> Enum.sort()
  end

  defp put_display(item, value) do
    if Regex.match?(@identifier, value),
      do: Map.put(item, "display", humanize(value)),
      else: item
  end

  defp humanize(text) do
    {first, rest} = text |> String.replace("_", " ") |> String.split_at(1)
    String.upcase(first) <> rest
  end

  defp render(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp render(value), do: inspect(value, printable_limit: @maximum_characters)

  defp truncate(text), do: String.slice(text, 0, @maximum_characters)
end
