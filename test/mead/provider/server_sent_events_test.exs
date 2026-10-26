defmodule Mead.Provider.ServerSentEventsTest do
  use ExUnit.Case, async: true

  alias Mead.Provider.ServerSentEvents

  @body "event: a\ndata: one\n\n: a comment\nevent: b\ndata: two\ndata: three\n\ndata:no space\n\n"
  @expected [
    %{event: "a", data: "one"},
    %{event: "b", data: "two\nthree"},
    %{event: nil, data: "no space"}
  ]

  defp parse_in_chunks(body, chunks) do
    {events, parser} =
      Enum.reduce(chunks, {[], ServerSentEvents.new()}, fn chunk, {collected, parser} ->
        {events, parser} = ServerSentEvents.feed(parser, chunk)
        {collected ++ events, parser}
      end)

    {events, parser, body}
  end

  defp bytes(body), do: for(<<byte <- body>>, do: <<byte>>)

  test "a whole body gives every event" do
    assert {@expected, _parser} = ServerSentEvents.feed(ServerSentEvents.new(), @body)
  end

  test "the same body byte by byte gives identical events" do
    assert {@expected, _parser, _body} = parse_in_chunks(@body, bytes(@body))
  end

  test "random chunk sizes with a fixed seed give identical events" do
    :rand.seed(:exsss, {1, 2, 3})

    for _run <- 1..50 do
      chunks = random_chunks(@body, [])
      assert {@expected, _parser, _body} = parse_in_chunks(@body, chunks)
    end
  end

  defp random_chunks("", chunks), do: Enum.reverse(chunks)

  defp random_chunks(body, chunks) do
    size = min(:rand.uniform(7), byte_size(body))
    <<chunk::binary-size(size), rest::binary>> = body
    random_chunks(rest, [chunk | chunks])
  end

  test "CRLF parses like LF, even split inside a pair" do
    body = String.replace(@body, "\n", "\r\n")

    assert {@expected, _parser} = ServerSentEvents.feed(ServerSentEvents.new(), body)
    assert {@expected, _parser, _body} = parse_in_chunks(body, bytes(body))
  end

  test "bare CR ends a line, and a trailing CR waits to see whether an LF follows" do
    body = String.replace(@body, "\n", "\r")

    {events, parser} = ServerSentEvents.feed(ServerSentEvents.new(), body)
    assert events == Enum.take(@expected, 2)

    {events, _parser} = ServerSentEvents.feed(parser, "x")
    assert events == [List.last(@expected)]
  end

  test "an event without its final blank line is not emitted yet" do
    {events, parser} = ServerSentEvents.feed(ServerSentEvents.new(), "event: a\ndata: one\n")
    assert events == []
    {events, _parser} = ServerSentEvents.feed(parser, "\n")
    assert events == [%{event: "a", data: "one"}]
  end

  test "an event with no data line is dropped and does not leak its name" do
    {events, _parser} =
      ServerSentEvents.feed(ServerSentEvents.new(), "event: ping\n\ndata: x\n\n")

    assert events == [%{event: nil, data: "x"}]
  end

  test "multibyte characters split across chunks survive" do
    body = "data: açaí ☕\n\n"
    assert {[%{data: "açaí ☕"}], _parser, _body} = parse_in_chunks(body, bytes(body))
  end
end
