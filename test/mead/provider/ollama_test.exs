defmodule Mead.Provider.OllamaTest do
  use ExUnit.Case, async: true

  alias Mead.Provider.Ollama

  @moduletag :capture_log

  @messages [%{role: :user, content: "hello"}]

  @tool %{
    name: "files__read_file",
    description: "Read a file",
    input_schema: %{"type" => "object"}
  }

  defp send_json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(data))
  end

  defp tool_call(name, arguments),
    do: %{"function" => %{"name" => name, "arguments" => arguments}}

  defp tool_reply(content, tool_calls) do
    %{
      "message" => %{"role" => "assistant", "content" => content, "tool_calls" => tool_calls},
      "prompt_eval_count" => 20,
      "eval_count" => 4
    }
  end

  defp use_call(id, name, input), do: %{type: :tool_use, id: id, name: name, input: input}

  defp result(id, content),
    do: %{type: :tool_result, tool_use_id: id, content: content, is_error: false}

  defp options(overrides \\ []) do
    Keyword.merge(
      [model: "llama3.1", req_options: [plug: {Req.Test, __MODULE__}]],
      overrides
    )
  end

  defp success_body(text \\ "hi there") do
    %{
      "message" => %{"role" => "assistant", "content" => text},
      "prompt_eval_count" => 11,
      "eval_count" => 7,
      "done" => true
    }
  end

  defp stub_capturing(reply \\ success_body()) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, JSON.decode!(raw_body)})
      Req.Test.json(conn, reply)
    end)
  end

  test "returns the text and the usage of a successful answer" do
    stub_capturing()

    assert Ollama.complete(@messages, options()) ==
             {:ok, %{text: "hi there", usage: %{input_tokens: 11, output_tokens: 7}}}

    assert_received {:request, "POST", "/api/chat", _body}
  end

  test "sends the model, stream false, and the messages, and no tools" do
    stub_capturing()

    Ollama.complete(@messages, options(model: "custom-model"))

    assert_received {:request, _method, _path, body}

    assert body == %{
             "model" => "custom-model",
             "stream" => false,
             "messages" => [%{"role" => "user", "content" => "hello"}]
           }
  end

  test "posts to the configured base url, with or without a trailing slash" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:target, conn.host, conn.port, conn.request_path})
      Req.Test.json(conn, success_body())
    end)

    for base_url <- ["http://ollama.internal:9999", "http://ollama.internal:9999/"] do
      assert {:ok, _result} = Ollama.complete(@messages, options(base_url: base_url))
      assert_received {:target, "ollama.internal", 9999, "/api/chat"}
    end
  end

  test "reports a timeout" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert Ollama.complete(@messages, options()) == {:error, :timeout}
  end

  test "reports a refused connection, which means Ollama is not running" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Ollama.complete(@messages, options()) == {:error, {:transport, :econnrefused}}
  end

  test "reports any other status with the status, including a 400 when no tools were sent" do
    for status <- [400, 404, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "nope") end)

      assert Ollama.complete(@messages, options()) == {:error, {:http_status, status}}
    end
  end

  test "never retries a failing request" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert Ollama.complete(@messages, options()) == {:error, {:http_status, 503}}
    assert Agent.get(counter, & &1) == 1
  end

  test "invalid options fail before anything is sent" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :network_reached)
      Req.Test.json(conn, success_body())
    end)

    invalid = [
      %{model: "llama3.1"},
      [req_options: [plug: {Req.Test, __MODULE__}]],
      options(model: ""),
      options(model: :llama),
      options(model: 123),
      options(base_url: :localhost),
      options(base_url: ""),
      options(req_options: %{plug: {Req.Test, __MODULE__}})
    ]

    for bad <- invalid do
      assert Ollama.complete(@messages, bad) == {:error, :invalid_options}
    end

    refute_received :network_reached
  end

  test "rejects an answer that does not carry a message, text, and integer counters" do
    empty_message = %{"role" => "assistant", "content" => ""}

    bodies = [
      %{},
      %{"message" => "text", "prompt_eval_count" => 1, "eval_count" => 1},
      %{"message" => empty_message, "prompt_eval_count" => 1, "eval_count" => 1},
      %{"message" => %{"content" => 42}, "prompt_eval_count" => 1, "eval_count" => 1},
      Map.delete(success_body(), "eval_count"),
      Map.delete(success_body(), "prompt_eval_count"),
      Map.put(success_body(), "eval_count", "7"),
      Map.put(success_body(), "prompt_eval_count", 1.5)
    ]

    for body <- bodies do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)

      assert Ollama.complete(@messages, options()) == {:error, :malformed_response}
    end

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
    assert Ollama.complete(@messages, options()) == {:error, :malformed_response}
  end

  describe "tools" do
    test "are encoded in the function form, with the description left out when absent" do
      stub_capturing()
      bare = %{name: "bare", description: nil, input_schema: %{"type" => "object"}}

      assert {:ok, _result} = Ollama.converse(@messages, [@tool, bare], options())

      assert_received {:request, "POST", "/api/chat", body}

      assert body["tools"] == [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "files__read_file",
                   "description" => "Read a file",
                   "parameters" => %{"type" => "object"}
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{"name" => "bare", "parameters" => %{"type" => "object"}}
               }
             ]
    end

    test "tool calls become tool_use blocks with synthesized ids and the tool_use stop reason" do
      calls = [
        tool_call("files__read_file", %{"path" => "/a"}),
        tool_call("files__read_file", %{"path" => "/b"})
      ]

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, tool_reply("", calls)) end)

      assert Ollama.converse(@messages, [@tool], options()) ==
               {:ok,
                %{
                  content: [
                    use_call("call_1", "files__read_file", %{"path" => "/a"}),
                    use_call("call_2", "files__read_file", %{"path" => "/b"})
                  ],
                  stop_reason: :tool_use,
                  usage: %{input_tokens: 20, output_tokens: 4}
                }}
    end

    test "text and tool calls in one answer keep both, text first" do
      reply = tool_reply("Let me look.", [tool_call("files__read_file", %{"path" => "/a"})])
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

      assert {:ok, %{content: [text, call], stop_reason: :tool_use}} =
               Ollama.converse(@messages, [@tool], options())

      assert text == %{type: :text, text: "Let me look."}
      assert call == use_call("call_1", "files__read_file", %{"path" => "/a"})
    end

    test "a null content next to a tool call is a normal answer" do
      reply = tool_reply(nil, [tool_call("files__read_file", %{})])
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

      assert {:ok, %{content: [%{type: :tool_use}], stop_reason: :tool_use}} =
               Ollama.converse(@messages, [@tool], options())
    end

    test "an answer with tool calls but no text is not a completion" do
      reply = tool_reply("", [tool_call("files__read_file", %{})])
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

      assert Ollama.complete(@messages, options()) == {:error, :malformed_response}
    end

    test "malformed tool calls are rejected, all or nothing" do
      valid = tool_call("files__read_file", %{})

      invalid = [
        [],
        "not a list",
        [%{"name" => "files__read_file"}],
        [%{"function" => %{"arguments" => %{}}}],
        [tool_call("", %{})],
        [tool_call("files__read_file", "{}")],
        [%{"function" => %{"name" => "files__read_file"}}],
        [valid, %{"function" => %{"arguments" => %{}}}]
      ]

      for tool_calls <- invalid do
        reply = tool_reply("", tool_calls)
        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

        assert Ollama.converse(@messages, [@tool], options()) == {:error, :malformed_response}
      end
    end
  end

  describe "a conversation with a tool exchange" do
    test "is encoded as an assistant message with tool_calls followed by tool messages" do
      stub_capturing()

      messages = [
        %{role: :user, content: "read both"},
        %{
          role: :assistant,
          content: [
            %{type: :text, text: "Reading."},
            use_call("call_1", "files__read_file", %{"path" => "/a"}),
            use_call("call_2", "files__list", %{"path" => "/"})
          ]
        },
        %{role: :user, content: [result("call_1", "contents"), result("call_2", "a, b")]}
      ]

      assert {:ok, _result} = Ollama.converse(messages, [@tool], options())

      assert_received {:request, _method, _path, body}

      assert body["messages"] == [
               %{"role" => "user", "content" => "read both"},
               %{
                 "role" => "assistant",
                 "content" => "Reading.",
                 "tool_calls" => [
                   %{
                     "function" => %{
                       "name" => "files__read_file",
                       "arguments" => %{"path" => "/a"}
                     }
                   },
                   %{"function" => %{"name" => "files__list", "arguments" => %{"path" => "/"}}}
                 ]
               },
               %{"role" => "tool", "content" => "contents", "tool_name" => "files__read_file"},
               %{"role" => "tool", "content" => "a, b", "tool_name" => "files__list"}
             ]
    end

    test "sends a result whose id matches no call without a tool name" do
      stub_capturing()

      messages = [
        %{role: :user, content: "read"},
        %{role: :assistant, content: [use_call("call_1", "files__read_file", %{})]},
        %{role: :user, content: [result("call_9", "orphan")]}
      ]

      assert {:ok, _result} = Ollama.converse(messages, [@tool], options())

      assert_received {:request, _method, _path, body}
      assert List.last(body["messages"]) == %{"role" => "tool", "content" => "orphan"}
    end

    test "names a result after the assistant message right before it when ids repeat across rounds" do
      stub_capturing()

      messages = [
        %{role: :user, content: "go"},
        %{role: :assistant, content: [use_call("call_1", "first_tool", %{})]},
        %{role: :user, content: [result("call_1", "one")]},
        %{role: :assistant, content: [use_call("call_1", "second_tool", %{})]},
        %{role: :user, content: [result("call_1", "two")]}
      ]

      assert {:ok, _result} = Ollama.converse(messages, [@tool], options())

      assert_received {:request, _method, _path, body}

      tool_names = for %{"role" => "tool", "tool_name" => name} <- body["messages"], do: name
      assert tool_names == ["first_tool", "second_tool"]
    end

    test "an assistant message with only tool calls carries an empty content" do
      stub_capturing()

      messages = [
        %{role: :user, content: "go"},
        %{role: :assistant, content: [use_call("call_1", "first_tool", %{})]},
        %{role: :user, content: [result("call_1", "one")]}
      ]

      assert {:ok, _result} = Ollama.converse(messages, [@tool], options())

      assert_received {:request, _method, _path, body}
      assert %{"role" => "assistant", "content" => ""} = Enum.at(body["messages"], 1)
    end
  end

  describe "a model without tool support" do
    test "a 400 that says so is :tools_unsupported when tools were sent" do
      message = "registry.ollama.ai/library/gemma2:9b does not support tools"

      Req.Test.stub(__MODULE__, fn conn -> send_json(conn, 400, %{"error" => message}) end)

      assert Ollama.converse(@messages, [@tool], options()) == {:error, :tools_unsupported}
    end

    test "the same 400 stays an http status when no tools were sent" do
      message = "registry.ollama.ai/library/gemma2:9b does not support tools"

      Req.Test.stub(__MODULE__, fn conn -> send_json(conn, 400, %{"error" => message}) end)

      assert Ollama.converse(@messages, [], options()) == {:error, {:http_status, 400}}
    end

    test "any other 400 stays an http status, JSON or not" do
      Req.Test.stub(__MODULE__, fn conn -> send_json(conn, 400, %{"error" => "invalid model"}) end)

      assert Ollama.converse(@messages, [@tool], options()) == {:error, {:http_status, 400}}

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "bad request") end)
      assert Ollama.converse(@messages, [@tool], options()) == {:error, {:http_status, 400}}

      Req.Test.stub(__MODULE__, fn conn -> send_json(conn, 400, %{"error" => 42}) end)
      assert Ollama.converse(@messages, [@tool], options()) == {:error, {:http_status, 400}}
    end
  end

  describe "review findings" do
    test "a base_url without an http or https scheme is :invalid_options, not a raise" do
      for base_url <- ["127.0.0.1:11434", "ftp://localhost:11434", "   ", "http://"] do
        assert Ollama.complete(@messages, options(base_url: base_url)) ==
                 {:error, :invalid_options}
      end
    end

    test "a receive_timeout that is not a positive integer is :invalid_options" do
      for receive_timeout <- ["abc", -1, 0, 1.5, nil] do
        assert Ollama.complete(@messages, options(receive_timeout: receive_timeout)) ==
                 {:error, :invalid_options}
      end
    end

    test "negative token counters are malformed" do
      for counters <- [%{"prompt_eval_count" => -3}, %{"eval_count" => -1}] do
        reply = Map.merge(success_body("hi"), counters)
        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

        assert Ollama.complete(@messages, options()) == {:error, :malformed_response}
      end
    end

    test "a body labeled JSON that is not JSON is malformed, on 200 and on 400" do
      for status <- [200, 400] do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, "{not json")
        end)

        assert Ollama.converse(@messages, [@tool], options()) == {:error, :malformed_response}
      end
    end

    test "a plain assistant message between rounds forgets the earlier tool names" do
      stub_capturing()

      messages = [
        %{role: :user, content: "go"},
        %{role: :assistant, content: [use_call("call_1", "old__tool", %{})]},
        %{role: :user, content: [result("call_1", "one")]},
        %{role: :assistant, content: "plain answer"},
        %{role: :user, content: [result("call_1", "stale")]}
      ]

      assert {:ok, _result} = Ollama.converse(messages, [@tool], options())

      assert_received {:request, _method, _path, body}
      assert List.last(body["messages"]) == %{"role" => "tool", "content" => "stale"}
    end

    test "an answer cut off by the token limit reports :max_tokens, not :end_turn" do
      reply = Map.put(success_body("half an ans"), "done_reason", "length")
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

      assert {:ok, %{stop_reason: :max_tokens, content: [%{type: :text, text: "half an ans"}]}} =
               Ollama.converse(@messages, [], options())
    end

    test "a finished answer and an unknown done_reason stay :end_turn" do
      for done_reason <- ["stop", "load", nil] do
        reply = Map.put(success_body("whole"), "done_reason", done_reason)
        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, reply) end)

        assert {:ok, %{stop_reason: :end_turn}} = Ollama.converse(@messages, [], options())
      end
    end
  end
end
