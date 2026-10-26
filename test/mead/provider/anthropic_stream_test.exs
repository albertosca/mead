defmodule Mead.Provider.AnthropicStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Provider.Anthropic

  @messages [%{role: :user, content: "list my files"}]
  @tools [%{name: "files__read_file", description: "Read", input_schema: %{"type" => "object"}}]

  defp event(name, payload), do: "event: #{name}\ndata: #{Jason.encode!(payload)}\n\n"

  defp start(input_tokens \\ 11),
    do:
      event("message_start", %{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => input_tokens, "output_tokens" => 1}}
      })

  defp block_start(index, block),
    do:
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => index,
        "content_block" => block
      })

  defp text_delta(index, text),
    do:
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "text_delta", "text" => text}
      })

  defp json_delta(index, json),
    do:
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      })

  defp block_stop(index),
    do: event("content_block_stop", %{"type" => "content_block_stop", "index" => index})

  defp finish(stop_reason, output_tokens),
    do:
      event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => output_tokens}
      }) <> event("message_stop", %{"type" => "message_stop"})

  defp text_body do
    start() <>
      block_start(0, %{"type" => "text", "text" => ""}) <>
      text_delta(0, "Hel") <>
      text_delta(0, "lo ") <> text_delta(0, "there") <> block_stop(0) <> finish("end_turn", 7)
  end

  defp tool_body do
    start() <>
      block_start(0, %{"type" => "text", "text" => ""}) <>
      text_delta(0, "Reading.") <>
      block_stop(0) <>
      block_start(1, %{"type" => "tool_use", "id" => "toolu_1", "name" => "files__read_file"}) <>
      json_delta(1, "") <>
      json_delta(1, ~s({"pa)) <>
      json_delta(1, ~s(th": "/a"})) <> block_stop(1) <> finish("tool_use", 9)
  end

  defp serve(body, chunk_size) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      body
      |> chunks(chunk_size)
      |> Enum.reduce(conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end
  end

  defp chunks(body, size) do
    for index <- 0..div(byte_size(body) - 1, size),
        do: binary_part(body, index * size, min(size, byte_size(body) - index * size))
  end

  defp options(plug, overrides \\ []) do
    Keyword.merge([api_key: "sk-secret", req_options: [plug: plug, retry_delay: 1]], overrides)
  end

  defp collect(plug, tools \\ @tools, overrides \\ []) do
    test_pid = self()
    on_delta = fn text -> send(test_pid, {:delta, text}) end
    result = Anthropic.converse_stream(@messages, tools, options(plug, overrides), on_delta)
    {result, deltas([])}
  end

  defp deltas(collected) do
    receive do
      {:delta, text} -> deltas(collected ++ [text])
    after
      0 -> collected
    end
  end

  test "a text stream gives the blocks, the usage and the fragments in order" do
    assert {{:ok, result}, ["Hel", "lo ", "there"]} = collect(serve(text_body(), 1_000))

    assert result == %{
             content: [%{type: :text, text: "Hello there"}],
             stop_reason: :end_turn,
             usage: %{input_tokens: 11, output_tokens: 7}
           }
  end

  test "text plus a tool use assembles the partial JSON" do
    assert {{:ok, result}, ["Reading."]} = collect(serve(tool_body(), 1_000))

    assert result.stop_reason == :tool_use

    assert result.content == [
             %{type: :text, text: "Reading."},
             %{type: :tool_use, id: "toolu_1", name: "files__read_file", input: %{"path" => "/a"}}
           ]
  end

  test "the stream equals the non-streaming result for the same content, at every chunk size" do
    plain =
      fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Hello there"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
        })
      end

    {:ok, expected} = Anthropic.converse(@messages, @tools, options(plain))

    for size <- [1, 2, 3, 7, 64, 100_000] do
      assert {{:ok, ^expected}, _deltas} = collect(serve(text_body(), size))
    end
  end

  test "a max_tokens stop is reported" do
    body =
      start() <>
        block_start(0, %{"type" => "text", "text" => ""}) <>
        text_delta(0, "cut") <> block_stop(0) <> finish("max_tokens", 1024)

    assert {{:ok, %{stop_reason: :max_tokens}}, ["cut"]} = collect(serve(body, 50))
  end

  test "an error event mid-stream keeps the delivered fragments and returns the reason" do
    body =
      start() <>
        block_start(0, %{"type" => "text", "text" => ""}) <>
        text_delta(0, "par") <>
        event("error", %{"type" => "error", "error" => %{"type" => "overloaded_error"}})

    assert {{:error, {:http_status, 529}}, ["par"]} = collect(serve(body, 10))
  end

  test "an HTTP 529 before any byte is retried and then reported" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 529, "overloaded")
    end

    assert {{:error, {:http_status, 529}}, []} = collect(plug)
    assert Agent.get(counter, & &1) == 3
  end

  test "a stream that ends without message_stop is malformed" do
    body = start() <> block_start(0, %{"type" => "text", "text" => ""}) <> text_delta(0, "x")
    assert {{:error, :malformed_response}, ["x"]} = collect(serve(body, 20))
  end

  test "a data line that is not JSON is malformed" do
    assert {{:error, :malformed_response}, []} = collect(serve("data: nope\n\n", 5))
  end

  test "a tool use whose JSON never completes is malformed" do
    body =
      start() <>
        block_start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "files__read_file"}) <>
        json_delta(0, ~s({"pa)) <> block_stop(0) <> finish("tool_use", 3)

    assert {{:error, :malformed_response}, []} = collect(serve(body, 30))
  end

  test "the request asks for a stream with the same headers as converse/3" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, Jason.decode!(raw), Plug.Conn.get_req_header(conn, "x-api-key"),
         Plug.Conn.get_req_header(conn, "anthropic-version")}
      )

      serve(text_body(), 1_000).(conn)
    end

    collect(plug)

    assert_received {:request, %{"stream" => true, "tools" => [_tool]}, ["sk-secret"],
                     ["2023-06-01"]}
  end

  test "the key never appears in a log line or a returned error" do
    log =
      capture_log(fn ->
        send(self(), {:outcome, collect(fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)})
      end)

    assert_received {:outcome, {{:error, reason}, []}}
    refute log =~ "sk-secret"
    refute inspect(reason) =~ "sk-secret"
  end

  test "bad options are refused before the key is used" do
    assert {:error, :invalid_options} =
             Anthropic.converse_stream(@messages, [], %{api_key: "sk-secret"}, fn _text -> :ok end)
  end
end
