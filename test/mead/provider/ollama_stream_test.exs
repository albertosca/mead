defmodule Mead.Provider.OllamaStreamTest do
  use ExUnit.Case, async: true

  alias Mead.Provider.Ollama

  @moduletag :capture_log

  @messages [%{role: :user, content: "hello"}]
  @tools [%{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}]

  defp line(object), do: Jason.encode!(object) <> "\n"

  defp piece(text),
    do: line(%{"message" => %{"role" => "assistant", "content" => text}, "done" => false})

  defp final(extra \\ %{}) do
    line(
      Map.merge(
        %{
          "message" => %{"role" => "assistant", "content" => ""},
          "done" => true,
          "done_reason" => "stop",
          "prompt_eval_count" => 20,
          "eval_count" => 4
        },
        extra
      )
    )
  end

  defp call_line(name, arguments),
    do:
      line(%{
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [%{"function" => %{"name" => name, "arguments" => arguments}}]
        },
        "done" => false
      })

  defp text_body, do: piece("Hel") <> piece("lo ") <> piece("there") <> final()

  defp tool_body do
    piece("Reading.") <>
      call_line("files__read_file", %{"path" => "/a"}) <>
      call_line("files__read_file", %{"path" => "/b"}) <> final(%{"done_reason" => "stop"})
  end

  defp serve(body, chunk_size) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      for index <- 0..div(byte_size(body) - 1, chunk_size), reduce: conn do
        conn ->
          chunk =
            binary_part(
              body,
              index * chunk_size,
              min(chunk_size, byte_size(body) - index * chunk_size)
            )

          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
      end
    end
  end

  defp options(plug, overrides \\ []),
    do: Keyword.merge([model: "llama3.1", req_options: [plug: plug]], overrides)

  defp collect(plug, tools \\ @tools, overrides \\ []) do
    test_pid = self()
    on_delta = fn text -> send(test_pid, {:delta, text}) end
    result = Ollama.converse_stream(@messages, tools, options(plug, overrides), on_delta)
    {result, deltas([])}
  end

  defp deltas(collected) do
    receive do
      {:delta, text} -> deltas(collected ++ [text])
    after
      0 -> collected
    end
  end

  defp plain(body_lines) do
    objects = body_lines |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    final = List.last(objects)
    content = objects |> Enum.map(& &1["message"]["content"]) |> Enum.join()
    calls = Enum.flat_map(objects, &(&1["message"]["tool_calls"] || []))
    message = %{"role" => "assistant", "content" => content}
    message = if calls == [], do: message, else: Map.put(message, "tool_calls", calls)
    Map.put(final, "message", message)
  end

  defp expected_from_plain(body) do
    plug = fn conn -> Req.Test.json(conn, plain(body)) end
    {:ok, expected} = Ollama.converse(@messages, @tools, options(plug))
    expected
  end

  test "a text stream gives the text, the usage and the fragments in order" do
    assert {{:ok, result}, ["Hel", "lo ", "there"]} = collect(serve(text_body(), 1_000))

    assert result == %{
             content: [%{type: :text, text: "Hello there"}],
             stop_reason: :end_turn,
             usage: %{input_tokens: 20, output_tokens: 4}
           }
  end

  test "tool calls are accumulated and get synthesized ids" do
    assert {{:ok, result}, ["Reading."]} = collect(serve(tool_body(), 1_000))
    assert result.stop_reason == :tool_use

    assert result.content == [
             %{type: :text, text: "Reading."},
             %{type: :tool_use, id: "call_1", name: "files__read_file", input: %{"path" => "/a"}},
             %{type: :tool_use, id: "call_2", name: "files__read_file", input: %{"path" => "/b"}}
           ]
  end

  test "the stream equals the non-streaming result, split at every byte and in big chunks" do
    for body <- [text_body(), tool_body()], size <- [1, 2, 5, 13, 100_000] do
      assert {{:ok, streamed}, _deltas} = collect(serve(body, size))
      assert streamed == expected_from_plain(body)
    end
  end

  test "a stream with no tools in the request still streams" do
    assert {{:ok, %{content: [%{text: "Hello there"}]}}, ["Hel", "lo ", "there"]} =
             collect(serve(text_body(), 9), [])
  end

  test "a blank line is skipped" do
    body = piece("a") <> "\n\n" <> piece("b") <> final()
    assert {{:ok, %{content: [%{text: "ab"}]}}, ["a", "b"]} = collect(serve(body, 4))
  end

  test "an invalid JSON line mid-stream is malformed and on_delta is not called again" do
    body = piece("one") <> "not json\n" <> piece("two") <> final()
    assert {{:error, :malformed_response}, ["one"]} = collect(serve(body, 7))
  end

  test "a stream without its final line is malformed" do
    assert {{:error, :malformed_response}, ["a"]} = collect(serve(piece("a"), 7))
  end

  test "a final line without the counts is malformed" do
    body = piece("a") <> line(%{"message" => %{"content" => ""}, "done" => true})
    assert {{:error, :malformed_response}, ["a"]} = collect(serve(body, 7))
  end

  test "HTTP 400 with tools is tools_unsupported, and a plain 500 is a status" do
    unsupported = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error": "registry.ollama.ai/x does not support tools"}))
    end

    assert {{:error, :tools_unsupported}, []} = collect(unsupported)

    assert {{:error, {:http_status, 500}}, []} =
             collect(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
  end

  test "a timeout is reported as timeout and the request asks for a stream" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(raw)})
      Req.Test.transport_error(conn, :timeout)
    end

    assert {{:error, :timeout}, []} = collect(plug)
    assert_received {:request, %{"stream" => true}}
  end

  test "bad options are refused before anything is sent" do
    assert {:error, :invalid_options} =
             Ollama.converse_stream(@messages, [], [req_options: []], fn _text -> :ok end)
  end
end
