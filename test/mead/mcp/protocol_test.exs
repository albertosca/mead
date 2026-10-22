defmodule Mead.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Protocol

  defp decoded(message), do: JSON.decode!(message)

  describe "encoding" do
    test "the initialize request names the pinned protocol version and no capabilities" do
      assert %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{
                 "protocolVersion" => "2025-06-18",
                 "capabilities" => %{},
                 "clientInfo" => %{"name" => "mead", "version" => version}
               }
             } = decoded(Protocol.initialize_request(1))

      assert is_binary(version)
    end

    test "the initialized notification has no id" do
      message = decoded(Protocol.initialized_notification())

      assert message == %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      refute Map.has_key?(message, "id")
    end

    test "the tool list request carries a cursor only when given one" do
      assert decoded(Protocol.list_tools_request(2))["params"] == %{}
      assert decoded(Protocol.list_tools_request(2, nil))["params"] == %{}

      assert decoded(Protocol.list_tools_request(2, "page-2"))["params"] == %{
               "cursor" => "page-2"
             }
    end

    test "the call request carries the name and the arguments" do
      assert decoded(Protocol.call_tool_request(3, "read_file", %{"path" => "/a"})) == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "tools/call",
               "params" => %{"name" => "read_file", "arguments" => %{"path" => "/a"}}
             }
    end

    test "no encoded message contains a raw newline, even when an argument does" do
      messages = [
        Protocol.initialize_request(1),
        Protocol.initialized_notification(),
        Protocol.list_tools_request(2, "a\nb"),
        Protocol.call_tool_request(3, "write", %{"text" => "line one\nline two\r\n"}),
        Protocol.result_response(4, %{}),
        Protocol.error_response(5, -32_601, "no\nmethod")
      ]

      for message <- messages do
        refute String.contains?(message, ["\n", "\r"])
      end
    end

    test "responses echo the id they answer" do
      assert decoded(Protocol.result_response("abc", %{"a" => 1})) ==
               %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{"a" => 1}}

      assert decoded(Protocol.error_response(9, -32_601, "Method not found")) ==
               %{
                 "jsonrpc" => "2.0",
                 "id" => 9,
                 "error" => %{"code" => -32_601, "message" => "Method not found"}
               }
    end
  end

  describe "decoding" do
    test "a result becomes a response" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1,"result":{"a":1}})) ==
               {:response, 1, %{"a" => 1}}
    end

    test "an error becomes an error response, with the data when there is some" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"bad"}})) ==
               {:error_response, 2, %{code: -32_602, message: "bad", data: nil}}

      assert Protocol.decode(
               ~s({"jsonrpc":"2.0","id":"x","error":{"code":1,"message":"m","data":{"k":true}}})
             ) == {:error_response, "x", %{code: 1, message: "m", data: %{"k" => true}}}
    end

    test "a method with an id is a request from the server" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":7,"method":"ping"})) ==
               {:request, 7, "ping", %{}}

      assert Protocol.decode(~s({"jsonrpc":"2.0","id":8,"method":"x","params":{"a":1}})) ==
               {:request, 8, "x", %{"a" => 1}}
    end

    test "a method without an id is a notification" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})) ==
               {:notification, "notifications/tools/list_changed", %{}}
    end

    test "empty, truncated, and non-UTF-8 input is malformed JSON" do
      assert Protocol.decode("") == {:invalid, :malformed_json}
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1,)) == {:invalid, :malformed_json}
      assert Protocol.decode(<<255, 254, 253>>) == {:invalid, :malformed_json}
    end

    test "valid JSON that is not a version 2 message is rejected" do
      assert Protocol.decode("null") == {:invalid, :not_jsonrpc}
      assert Protocol.decode("[]") == {:invalid, :not_jsonrpc}

      assert Protocol.decode(~s([{"jsonrpc":"2.0","id":1,"result":{}}])) ==
               {:invalid, :not_jsonrpc}

      assert Protocol.decode(~s({"id":1,"result":{}})) == {:invalid, :not_jsonrpc}
      assert Protocol.decode(~s({"jsonrpc":"1.0","id":1,"result":{}})) == {:invalid, :not_jsonrpc}
    end

    test "a message with both a result and an error is rejected" do
      assert Protocol.decode(
               ~s({"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"m"}})
             ) == {:invalid, :result_and_error}
    end

    test "an id of the wrong type, a null id, or a result that is not an object is unrecognized" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1.5,"result":{}})) ==
               {:invalid, :unrecognized}

      assert Protocol.decode(~s({"jsonrpc":"2.0","id":null,"result":{}})) ==
               {:invalid, :unrecognized}

      assert Protocol.decode(~s({"jsonrpc":"2.0","id":{"a":1},"result":{}})) ==
               {:invalid, :unrecognized}

      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1,"result":"text"})) ==
               {:invalid, :unrecognized}

      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1,"error":{"code":"x","message":"m"}})) ==
               {:invalid, :unrecognized}
    end

    test "a message with neither a result, an error, nor a method is unrecognized" do
      assert Protocol.decode(~s({"jsonrpc":"2.0","id":1})) == {:invalid, :unrecognized}
      assert Protocol.decode(~s({"jsonrpc":"2.0"})) == {:invalid, :unrecognized}
    end

    test "input that is not a binary is rejected without raising" do
      assert Protocol.decode(nil) == {:invalid, :not_binary}
      assert Protocol.decode(%{}) == {:invalid, :not_binary}
    end
  end

  test "only the pinned protocol version is supported" do
    assert Protocol.protocol_version() == "2025-06-18"
    assert Protocol.supported_version?("2025-06-18")
    refute Protocol.supported_version?("2024-11-05")
    refute Protocol.supported_version?(nil)
  end
end
