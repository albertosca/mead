defmodule Mead.Provider.AnthropicConverseTest do
  use ExUnit.Case, async: true

  alias Mead.Provider.Anthropic

  @moduletag :capture_log

  @messages [%{role: :user, content: "list my files"}]

  @tools [
    %{
      name: "files__read_file",
      description: "Read a file",
      input_schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
    }
  ]

  defp options(plug, overrides \\ []) do
    Keyword.merge([api_key: "sk-test", req_options: [plug: plug, retry_delay: 1]], overrides)
  end

  defp reply(body), do: fn conn -> Req.Test.json(conn, body) end

  @usage %{"input_tokens" => 11, "output_tokens" => 7}

  test "sends the tools with input_schema, and omits the key when there are none" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, JSON.decode!(raw_body)})

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}], "usage" => @usage})
    end

    assert {:ok, _reply} = Anthropic.converse(@messages, @tools, options(plug))
    assert_receive {:body, with_tools}

    assert with_tools["tools"] == [
             %{
               "name" => "files__read_file",
               "description" => "Read a file",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{"path" => %{"type" => "string"}}
               }
             }
           ]

    assert {:ok, _reply} = Anthropic.converse(@messages, [], options(plug))
    assert_receive {:body, without_tools}
    refute Map.has_key?(without_tools, "tools")
  end

  test "a tool without a description is sent without the key" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, JSON.decode!(raw_body)})

      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}], "usage" => @usage})
    end

    tool = %{name: "a__b", description: nil, input_schema: %{"type" => "object"}}
    Anthropic.converse(@messages, [tool], options(plug))

    assert_receive {:body, %{"tools" => [sent]}}
    assert sent == %{"name" => "a__b", "input_schema" => %{"type" => "object"}}
  end

  test "returns a text answer as blocks with the end_turn stop reason" do
    plug =
      reply(%{
        "content" => [%{"type" => "text", "text" => "hello"}],
        "stop_reason" => "end_turn",
        "usage" => @usage
      })

    assert Anthropic.converse(@messages, @tools, options(plug)) ==
             {:ok,
              %{
                content: [%{type: :text, text: "hello"}],
                stop_reason: :end_turn,
                usage: %{input_tokens: 11, output_tokens: 7}
              }}
  end

  test "a missing stop reason is an ordinary end of turn" do
    plug = reply(%{"content" => [%{"type" => "text", "text" => "hello"}], "usage" => @usage})

    assert {:ok, %{stop_reason: :end_turn}} = Anthropic.converse(@messages, [], options(plug))
  end

  test "returns tool_use blocks with the tool_use stop reason" do
    plug =
      reply(%{
        "content" => [
          %{"type" => "text", "text" => "let me look"},
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "files__read_file",
            "input" => %{"path" => "/a"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => @usage
      })

    assert {:ok, %{content: content, stop_reason: :tool_use}} =
             Anthropic.converse(@messages, @tools, options(plug))

    assert content == [
             %{type: :text, text: "let me look"},
             %{type: :tool_use, id: "toolu_1", name: "files__read_file", input: %{"path" => "/a"}}
           ]
  end

  test "blocks of an unknown type are dropped" do
    plug =
      reply(%{
        "content" => [
          %{"type" => "thinking", "thinking" => "..."},
          %{"type" => "text", "text" => "hi"}
        ],
        "usage" => @usage
      })

    assert {:ok, %{content: [%{type: :text, text: "hi"}]}} =
             Anthropic.converse(@messages, [], options(plug))
  end

  test "a tool_use stop reason without a usable tool_use block is malformed" do
    plug =
      reply(%{
        "content" => [%{"type" => "text", "text" => "hmm"}],
        "stop_reason" => "tool_use",
        "usage" => @usage
      })

    assert Anthropic.converse(@messages, @tools, options(plug)) == {:error, :malformed_response}
  end

  test "a tool_use block with an input that is not an object is dropped, so it is malformed" do
    plug =
      reply(%{
        "content" => [%{"type" => "tool_use", "id" => "t", "name" => "n", "input" => "oops"}],
        "stop_reason" => "tool_use",
        "usage" => @usage
      })

    assert Anthropic.converse(@messages, @tools, options(plug)) == {:error, :malformed_response}
  end

  test "an answer with no usable block at all is malformed" do
    plug = reply(%{"content" => [%{"type" => "thinking"}], "usage" => @usage})
    assert Anthropic.converse(@messages, [], options(plug)) == {:error, :malformed_response}

    plug = reply(%{"content" => [], "usage" => @usage})
    assert Anthropic.converse(@messages, [], options(plug)) == {:error, :malformed_response}
  end

  test "messages carrying blocks are encoded the way the API expects" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, JSON.decode!(raw_body)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "done"}],
        "usage" => @usage
      })
    end

    messages =
      @messages ++
        [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_use,
                id: "toolu_1",
                name: "files__read_file",
                input: %{"path" => "/a"}
              }
            ]
          },
          %{
            role: :user,
            content: [
              %{type: :tool_result, tool_use_id: "toolu_1", content: "contents", is_error: false}
            ]
          }
        ]

    assert {:ok, _reply} = Anthropic.converse(messages, @tools, options(plug))
    assert_receive {:body, body}

    assert Enum.at(body["messages"], 1) == %{
             "role" => "assistant",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "files__read_file",
                 "input" => %{"path" => "/a"}
               }
             ]
           }

    assert Enum.at(body["messages"], 2) == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_1",
                 "content" => "contents",
                 "is_error" => false
               }
             ]
           }
  end

  test "the failures of complete/2 are the failures of converse/3" do
    for {plug, reason} <- [
          {fn conn -> Plug.Conn.send_resp(conn, 401, "") end, {:http_status, 401}},
          {fn conn -> Req.Test.transport_error(conn, :timeout) end, :timeout}
        ] do
      assert Anthropic.converse(@messages, @tools, options(plug)) == {:error, reason}
    end

    assert Anthropic.converse(@messages, @tools, api_key: "k", req_options: %{}) ==
             {:error, :invalid_options}
  end

  test "complete/2 still returns the joined text, and rejects an answer that has only tool_use" do
    texts =
      reply(%{
        "content" => [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}],
        "usage" => @usage
      })

    assert Anthropic.complete(@messages, options(texts)) ==
             {:ok, %{text: "ab", usage: %{input_tokens: 11, output_tokens: 7}}}

    only_tool =
      reply(%{
        "content" => [%{"type" => "tool_use", "id" => "t", "name" => "n", "input" => %{}}],
        "usage" => @usage
      })

    assert Anthropic.complete(@messages, options(only_tool)) == {:error, :malformed_response}
  end
end
