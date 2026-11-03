defmodule Mead.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Provider.Anthropic

  @moduletag :capture_log

  # A recognizable key, so a test can prove it never leaks into a reason, a log, or an event.
  @sentinel_key "sk-test-SENTINEL-0123456789"

  @messages [%{role: :user, content: "hello"}]

  defp options(overrides \\ []) do
    Keyword.merge(
      [
        api_key: @sentinel_key,
        req_options: [plug: {Req.Test, __MODULE__}, retry_delay: 1]
      ],
      overrides
    )
  end

  defp success_body(text \\ "hi there") do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
    }
  end

  test "returns the text and the usage of a successful reply" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@sentinel_key]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      Req.Test.json(conn, success_body())
    end)

    assert Anthropic.complete(@messages, options()) ==
             {:ok, %{text: "hi there", usage: %{input_tokens: 11, output_tokens: 7}}}
  end

  test "a reply cut off by the token limit reports :max_tokens through converse" do
    reply = Map.put(success_body("half an ans"), "stop_reason", "max_tokens")
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

    assert {:ok, %{stop_reason: :max_tokens}} = Anthropic.converse(@messages, [], options())
  end

  test "sends the model, the token limit, and the messages" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, JSON.decode!(raw_body)})
      Req.Test.json(conn, success_body())
    end)

    Anthropic.complete(@messages, options(model: "custom-model", max_tokens: 50))

    assert_received {:request_body, body}

    assert body == %{
             "model" => "custom-model",
             "max_tokens" => 50,
             "messages" => [%{"role" => "user", "content" => "hello"}]
           }
  end

  test "joins several text blocks and ignores the others" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{"type" => "text", "text" => "one "},
          %{"type" => "tool_use", "id" => "x"},
          %{"type" => "text", "text" => "two"}
        ],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })
    end)

    assert {:ok, %{text: "one two"}} = Anthropic.complete(@messages, options())
  end

  test "retries a 429 and succeeds on the next attempt" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> Plug.Conn.send_resp(conn, 429, "slow down")
        _later -> Req.Test.json(conn, success_body())
      end
    end)

    assert {:ok, %{text: "hi there"}} = Anthropic.complete(@messages, options())
    assert Agent.get(counter, & &1) == 2
  end

  test "gives up after two retries of a persistent 5xx" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert Anthropic.complete(@messages, options()) == {:error, {:http_status, 503}}
    assert Agent.get(counter, & &1) == 3
  end

  test "does not retry a client error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end)

    assert Anthropic.complete(@messages, options()) == {:error, {:http_status, 401}}
    assert Agent.get(counter, & &1) == 1
  end

  describe "a refused request" do
    defp refuse(status, error) do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"type" => "error", "error" => error})
      end)
    end

    test "logs the type and message the API gave, and keeps the reason a status" do
      message = "Your credit balance is too low to access the Anthropic API."
      refuse(400, %{"type" => "invalid_request_error", "message" => message})

      log =
        capture_log(fn ->
          assert Anthropic.complete(@messages, options()) == {:error, {:http_status, 400}}
        end)

      assert log =~ "HTTP 400"
      assert log =~ "invalid_request_error"
      assert log =~ message
      refute log =~ @sentinel_key
    end

    test "a body that is not the API's error shape still logs the status" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

      log =
        capture_log(fn ->
          assert Anthropic.complete(@messages, options()) == {:error, {:http_status, 401}}
        end)

      assert log =~ "HTTP 401"
      refute log =~ @sentinel_key
    end

    test "a very long message is cut in the log" do
      refuse(400, %{"type" => "invalid_request_error", "message" => String.duplicate("a", 5_000)})

      log = capture_log(fn -> Anthropic.complete(@messages, options()) end)

      assert log =~ String.duplicate("a", 200)
      refute log =~ String.duplicate("a", 501)
    end
  end

  test "reports a timeout without retrying it" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.transport_error(conn, :timeout)
    end)

    assert Anthropic.complete(@messages, options()) == {:error, :timeout}
    assert Agent.get(counter, & &1) == 1
  end

  test "reports another transport error with its reason" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Anthropic.complete(@messages, options()) == {:error, {:transport, :econnrefused}}
  end

  test "rejects a reply that does not carry text and usage" do
    for body <- [%{}, %{"content" => []}, %{"content" => [%{"type" => "text", "text" => "x"}]}] do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)

      assert Anthropic.complete(@messages, options()) == {:error, :malformed_response}
    end

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
    assert Anthropic.complete(@messages, options()) == {:error, :malformed_response}
  end

  test "a long retry-after is capped, and a persistent 429 is reported after two retries" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("retry-after", "3600")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    started_at = System.monotonic_time(:millisecond)

    assert Anthropic.complete(
             @messages,
             options(maximum_retry_delay: 10, req_options: [plug: {Req.Test, __MODULE__}])
           ) ==
             {:error, {:http_status, 429}}

    assert System.monotonic_time(:millisecond) - started_at < 30_000
    assert Agent.get(counter, & &1) == 3
  end

  test "options that are not keyword lists fail without echoing the key" do
    log =
      capture_log(fn ->
        assert Anthropic.complete(@messages, %{api_key: @sentinel_key}) ==
                 {:error, :invalid_options}

        assert Anthropic.complete(
                 @messages,
                 options(req_options: %{plug: {Req.Test, __MODULE__}})
               ) == {:error, :invalid_options}
      end)

    refute log =~ @sentinel_key
  end

  describe "the API key" do
    @describetag :tmp_dir

    test "is read from the key file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "api.env")
      File.write!(path, "OTHER=1\nexport ANTHROPIC_API_KEY=\"#{@sentinel_key}\"\n")

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == [@sentinel_key]
        Req.Test.json(conn, success_body())
      end)

      options = options(api_key_file: path) |> Keyword.delete(:api_key)
      assert {:ok, %{text: "hi there"}} = Anthropic.complete(@messages, options)
    end

    test "missing from a file without it, an empty value, or no file at all", %{
      tmp_dir: tmp_dir
    } do
      unrelated = Path.join(tmp_dir, "unrelated.env")
      empty = Path.join(tmp_dir, "empty.env")
      File.write!(unrelated, "OTHER=1\n")
      File.write!(empty, "ANTHROPIC_API_KEY=\n")

      for path <- [unrelated, empty, Path.join(tmp_dir, "absent.env")] do
        options = options(api_key_file: path) |> Keyword.delete(:api_key)
        assert Anthropic.complete(@messages, options) == {:error, :missing_api_key}
      end
    end

    test "never appears in a returned reason or a log line" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      log =
        capture_log(fn ->
          assert {:error, reason} = Anthropic.complete(@messages, options())
          refute inspect(reason) =~ @sentinel_key
        end)

      refute log =~ @sentinel_key
    end
  end

  describe "thinking blocks" do
    defp answer(content, stop_reason \\ "tool_use") do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => content,
          "stop_reason" => stop_reason,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
        })
      end)
    end

    @tool_use %{
      "type" => "tool_use",
      "id" => "toolu_1",
      "name" => "files__read_file",
      "input" => %{"path" => "/a"}
    }

    test "are kept verbatim and in order with text and tool use" do
      answer([
        %{"type" => "thinking", "thinking" => "", "signature" => "signature-one"},
        %{"type" => "text", "text" => "Reading."},
        %{"type" => "redacted_thinking", "data" => "opaque"},
        @tool_use,
        %{"type" => "thinking", "thinking" => "Then the second.", "signature" => "signature-two"},
        Map.put(@tool_use, "id", "toolu_2")
      ])

      assert {:ok, %{content: content, stop_reason: :tool_use}} =
               Anthropic.converse(@messages, [], options())

      assert content == [
               %{type: :thinking, thinking: "", signature: "signature-one"},
               %{type: :text, text: "Reading."},
               %{type: :redacted_thinking, data: "opaque"},
               %{
                 type: :tool_use,
                 id: "toolu_1",
                 name: "files__read_file",
                 input: %{"path" => "/a"}
               },
               %{type: :thinking, thinking: "Then the second.", signature: "signature-two"},
               %{
                 type: :tool_use,
                 id: "toolu_2",
                 name: "files__read_file",
                 input: %{"path" => "/a"}
               }
             ]
    end

    test "a thinking block without a signature, or a redacted one without data, is malformed" do
      for broken <- [
            %{"type" => "thinking", "thinking" => "x"},
            %{"type" => "thinking", "thinking" => "x", "signature" => ""},
            %{"type" => "thinking", "thinking" => "x", "signature" => nil},
            %{"type" => "thinking", "signature" => "signature-one"},
            %{"type" => "redacted_thinking"},
            %{"type" => "redacted_thinking", "data" => 7}
          ] do
        answer([broken, %{"type" => "text", "text" => "hi"}], "end_turn")

        assert Anthropic.converse(@messages, [], options()) == {:error, :malformed_response}
      end
    end

    test "an answer holding only thinking, with no text and no tool use, is malformed" do
      answer(
        [
          %{"type" => "thinking", "thinking" => "", "signature" => "signature-one"},
          %{"type" => "redacted_thinking", "data" => "opaque"}
        ],
        "end_turn"
      )

      assert Anthropic.converse(@messages, [], options()) == {:error, :malformed_response}
    end

    test "complete/2 still returns only the text" do
      answer(
        [
          %{"type" => "thinking", "thinking" => "private reasoning", "signature" => "s"},
          %{"type" => "text", "text" => "hi"}
        ],
        "end_turn"
      )

      assert {:ok, %{text: "hi"}} = Anthropic.complete(@messages, options())
    end

    test "go back to the API in the shape it sent them" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, JSON.decode!(raw_body)})
        Req.Test.json(conn, success_body())
      end)

      messages = [
        %{role: :user, content: "read /a"},
        %{
          role: :assistant,
          content: [
            %{type: :thinking, thinking: "", signature: "signature-one"},
            %{type: :redacted_thinking, data: "opaque"}
          ]
        },
        %{role: :user, content: "go on"}
      ]

      Anthropic.converse(messages, [], options())

      assert_received {:request_body, %{"messages" => [_first, assistant, _last]}}

      assert assistant["content"] == [
               %{"type" => "thinking", "thinking" => "", "signature" => "signature-one"},
               %{"type" => "redacted_thinking", "data" => "opaque"}
             ]
    end
  end

  describe "block binding" do
    defp capture_request do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        beta = Plug.Conn.get_req_header(conn, "anthropic-beta")
        send(test_pid, {:request, beta, JSON.decode!(raw_body)})
        Req.Test.json(conn, success_body())
      end)
    end

    test ":drop_block sends the beta header and the field" do
      capture_request()
      assert {:ok, _reply} = Anthropic.complete(@messages, options(block_binding: :drop_block))
      assert_received {:request, ["thinking-binding-controls-2026-08-01"], body}

      assert body["thinking"] == %{
               "type" => "adaptive",
               "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
             }
    end

    test ":error sends error as the behavior" do
      capture_request()
      assert {:ok, _reply} = Anthropic.complete(@messages, options(block_binding: :error))
      assert_received {:request, ["thinking-binding-controls-2026-08-01"], body}
      assert body["thinking"]["block_binding"] == %{"prefix_mismatch_behavior" => "error"}
    end

    test "absent, the request has neither the header nor the field" do
      capture_request()
      assert {:ok, _reply} = Anthropic.complete(@messages, options())
      assert_received {:request, [], body}
      refute Map.has_key?(body, "thinking")
    end

    test "any other value is invalid options and sends nothing" do
      capture_request()

      for value <- [:drop, "drop_block", true, nil] do
        assert Anthropic.complete(@messages, options(block_binding: value)) ==
                 {:error, :invalid_options}
      end

      refute_received {:request, _beta, _body}
    end
  end

  describe "input_transformations" do
    defp transformed(entries) do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, Map.put(success_body(), "input_transformations", entries))
      end)
    end

    test "a non-empty list logs type, reason and path, and the answer is unchanged" do
      transformed([
        %{
          "type" => "thinking_dropped",
          "path" => "messages.1.content.0",
          "reason" => "prefix_binding_mismatch"
        }
      ])

      log =
        capture_log(fn ->
          assert {:ok, %{text: "hi there"}} = Anthropic.complete(@messages, options())
        end)

      assert log =~ "replayed thinking block"
      assert log =~ "thinking_dropped"
      assert log =~ "prefix_binding_mismatch"
      assert log =~ "messages.1.content.0"
      refute log =~ @sentinel_key
    end

    test "an entry never logs a field other than type, reason and path" do
      transformed([
        %{
          "type" => "thinking_dropped",
          "path" => "messages.1.content.0",
          "reason" => "prefix_binding_mismatch",
          "signature" => "SIGNATURE-MUST-NOT-LEAK",
          "thinking" => "REASONING-MUST-NOT-LEAK"
        }
      ])

      log = capture_log(fn -> Anthropic.complete(@messages, options()) end)

      assert log =~ "thinking_dropped"
      refute log =~ "MUST-NOT-LEAK"
    end

    test "an empty list, or none, logs nothing about it" do
      for entries <- [[], nil] do
        transformed(entries)
        log = capture_log(fn -> Anthropic.complete(@messages, options()) end)
        refute log =~ "replayed thinking block"
      end
    end

    test "an entry that is not a map is logged without crashing" do
      transformed(["unexpected"])

      log =
        capture_log(fn ->
          assert {:ok, %{text: "hi there"}} = Anthropic.complete(@messages, options())
        end)

      assert log =~ "replayed thinking block"
    end
  end

  @tag :live
  test "talks to the real API" do
    assert {:ok, %{text: text, usage: %{input_tokens: input_tokens}}} =
             Anthropic.complete([%{role: :user, content: "Reply with the single word: pong"}],
               max_tokens: 20
             )

    assert is_binary(text) and text != ""
    assert input_tokens > 0
  end
end
