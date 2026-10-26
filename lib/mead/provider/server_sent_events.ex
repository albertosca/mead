defmodule Mead.Provider.ServerSentEvents do
  @moduledoc """
  An incremental parser for `text/event-stream` bodies.

  `feed/2` takes the bytes as they arrive, split anywhere, and returns the events that became
  complete with them. A line ends with `\\n`, `\\r\\n` or `\\r`; an event ends with an empty line, so
  an event whose terminator has not arrived yet stays buffered and is never emitted half-built.
  Comment lines (starting with `:`) are dropped, several `data:` lines of one event are joined with
  a newline, and an event with no `data:` line is dropped.
  """

  @enforce_keys [:buffer, :event, :data]
  defstruct [:buffer, :event, :data]

  @type event :: %{event: String.t() | nil, data: String.t()}
  @type t :: %__MODULE__{buffer: binary(), event: String.t() | nil, data: [String.t()]}

  @spec new() :: t()
  def new, do: %__MODULE__{buffer: "", event: nil, data: []}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    {lines, rest} = split_lines(parser.buffer <> chunk)

    {events, parser} =
      Enum.reduce(lines, {[], %{parser | buffer: ""}}, fn line, {events, current} ->
        case line_step(line, current) do
          {:event, event, next} -> {[event | events], next}
          {:continue, next} -> {events, next}
        end
      end)

    {Enum.reverse(events), %{parser | buffer: rest}}
  end

  # A trailing `\r` could be the first half of `\r\n`, so it waits for the next byte.
  defp split_lines(text), do: split_lines(text, "", [])

  defp split_lines("", current, lines), do: {Enum.reverse(lines), current}
  defp split_lines("\r", current, lines), do: {Enum.reverse(lines), current <> "\r"}
  defp split_lines("\r\n" <> rest, current, lines), do: split_lines(rest, "", [current | lines])
  defp split_lines("\r" <> rest, current, lines), do: split_lines(rest, "", [current | lines])
  defp split_lines("\n" <> rest, current, lines), do: split_lines(rest, "", [current | lines])

  defp split_lines(<<byte, rest::binary>>, current, lines),
    do: split_lines(rest, current <> <<byte>>, lines)

  defp line_step("", %__MODULE__{data: []} = parser), do: {:continue, %{parser | event: nil}}

  defp line_step("", parser) do
    event = %{event: parser.event, data: parser.data |> Enum.reverse() |> Enum.join("\n")}
    {:event, event, %{parser | event: nil, data: []}}
  end

  defp line_step(":" <> _comment, parser), do: {:continue, parser}

  defp line_step(line, parser) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    case field do
      "event" -> {:continue, %{parser | event: value}}
      "data" -> {:continue, %{parser | data: [value | parser.data]}}
      _ignored -> {:continue, parser}
    end
  end
end
