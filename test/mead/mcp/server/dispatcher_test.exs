defmodule Mead.MCP.Server.DispatcherTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Protocol
  alias Mead.MCP.Server.Dispatcher

  @context %{allow_effect: false}

  defp request(id, method, params \\ %{}), do: {:request, id, method, params}

  defp reply(message, context \\ @context) do
    assert {:reply, body} = Dispatcher.dispatch(message, context)
    refute String.contains?(body, ["\n", "\r"])
    JSON.decode!(body)
  end

  describe "initialize" do
    test "answers with the pinned version, the tools capability, and the server info" do
      response = reply(request(1, "initialize", %{"protocolVersion" => "2025-06-18"}))

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == Protocol.protocol_version()
      assert response["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert %{"name" => "mead", "version" => version} = response["result"]["serverInfo"]
      assert is_binary(version)
    end

    test "a client that asks for another version is answered with ours" do
      response = reply(request(2, "initialize", %{"protocolVersion" => "2024-11-05"}))

      assert response["result"]["protocolVersion"] == "2025-06-18"
    end

    test "a missing or non-string version is invalid params" do
      for params <- [%{}, %{"protocolVersion" => 20_250_618}, %{"protocolVersion" => nil}] do
        response = reply(request(3, "initialize", params))

        assert response["error"]["code"] == -32_602
        assert response["id"] == 3
        refute Map.has_key?(response, "result")
      end
    end
  end

  test "the id is echoed as given, integer or string" do
    assert reply(request(7, "ping"))["id"] == 7
    assert reply(request("abc-1", "ping"))["id"] == "abc-1"
  end

  test "ping answers an empty result" do
    assert reply(request(1, "ping"))["result"] == %{}
  end

  test "tools/list offers the nine tools" do
    response = reply(request(1, "tools/list"))

    assert Enum.map(response["result"]["tools"], & &1["name"]) ==
             [
               "start_session",
               "submit_turn",
               "history",
               "stop_session",
               "resume_session",
               "delete_session",
               "list_sessions",
               "compact_session",
               "usage"
             ]
  end

  describe "tools/call" do
    test "runs a tool and returns its result" do
      response = reply(request(1, "tools/call", %{"name" => "start_session"}))
      session_id = response["result"]["content"] |> hd() |> Map.fetch!("text")
      on_exit(fn -> Mead.stop_session(session_id) end)

      assert response["result"]["isError"] == false
      assert {:ok, []} = Mead.history(session_id)
    end

    test "a tool failure is a result flagged isError, never a JSON-RPC error" do
      response =
        reply(
          request(1, "tools/call", %{
            "name" => "history",
            "arguments" => %{"session_id" => "no-such-session"}
          })
        )

      assert response["result"]["isError"] == true
      refute Map.has_key?(response, "error")
    end

    test "an unknown tool is invalid params" do
      response = reply(request(1, "tools/call", %{"name" => "nope"}))

      assert response["error"] == %{"code" => -32_602, "message" => "unknown tool"}
    end

    test "a name that is not a string, or no name at all, is invalid params" do
      for params <- [%{}, %{"name" => 5}, %{"name" => nil}, %{"arguments" => %{}}] do
        assert reply(request(1, "tools/call", params))["error"]["code"] == -32_602
      end
    end

    test "arguments that are not an object are invalid params" do
      for arguments <- ["x", 5, [], nil] do
        response =
          reply(request(1, "tools/call", %{"name" => "history", "arguments" => arguments}))

        assert response["error"]["code"] == -32_602
      end
    end

    test "arguments of the wrong type inside a known tool are invalid params" do
      response =
        reply(
          request(1, "tools/call", %{
            "name" => "history",
            "arguments" => %{"session_id" => 12}
          })
        )

      assert response["error"] == %{
               "code" => -32_602,
               "message" => "session_id must be a string"
             }
    end

    test "the context's allow_effect reaches the tool" do
      {:ok, session_id} = Mead.start_session()
      on_exit(fn -> Mead.stop_session(session_id) end)

      call =
        request(1, "tools/call", %{
          "name" => "submit_turn",
          "arguments" => %{"session_id" => session_id, "input" => "hi", "tools" => "effect"}
        })

      closed = reply(call, %{allow_effect: false})
      assert closed["result"]["isError"] == true
      assert closed["result"]["content"] |> hd() |> Map.fetch!("text") =~ "not enabled"

      open = reply(call, %{allow_effect: true})
      assert open["result"]["isError"] == false
    end
  end

  test "an unknown method is method not found" do
    response = reply(request(1, "resources/list"))

    assert response["error"] == %{"code" => -32_601, "message" => "method not found"}
    assert response["id"] == 1
  end

  test "notifications and responses produce no reply" do
    assert Dispatcher.dispatch({:notification, "notifications/initialized", %{}}, @context) ==
             :no_reply

    assert Dispatcher.dispatch({:notification, "anything/at/all", %{}}, @context) == :no_reply
    assert Dispatcher.dispatch({:response, 1, %{}}, @context) == :no_reply

    assert Dispatcher.dispatch(
             {:error_response, 1, %{code: -1, message: "x", data: nil}},
             @context
           ) == :no_reply
  end
end
