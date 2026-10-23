defmodule Mead.MCP.Server.ToolsTest.NonStringHandler do
  @moduledoc false
  @behaviour Mead.Session.TurnHandler

  @impl true
  def handle_turn(_history, _input, _options), do: {:ok, %{reply: [1, 2, 3]}}
end

defmodule Mead.MCP.Server.ToolsTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.Server.Tools
  alias Mead.MCP.Server.ToolsTest.NonStringHandler
  alias Mead.Test.TextHandler

  @closed %{allow_effect: false}
  @open %{allow_effect: true}

  defp start_session!(options \\ []) do
    {:ok, session_id} = Mead.start_session(Keyword.merge([handler: TextHandler], options))
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  defp submit(session_id, input, arguments \\ %{}, context \\ @closed) do
    Tools.call(
      "submit_turn",
      Map.merge(%{"session_id" => session_id, "input" => input}, arguments),
      context
    )
  end

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  test "definitions list the four tools, each with an object schema" do
    definitions = Tools.definitions()

    assert Enum.map(definitions, & &1["name"]) ==
             ["start_session", "submit_turn", "history", "stop_session"]

    for definition <- definitions do
      assert is_binary(definition["description"])
      assert definition["inputSchema"]["type"] == "object"
    end

    submit_schema = Enum.find(definitions, &(&1["name"] == "submit_turn"))["inputSchema"]
    assert submit_schema["required"] == ["session_id", "input"]
    assert submit_schema["properties"]["route"]["enum"] == ["auto", "local", "cloud"]
    assert submit_schema["properties"]["tools"]["enum"] == ["effect"]
    assert submit_schema["properties"]["input"]["maxLength"] == 100_000
  end

  test "an unknown tool is reported as such, whatever the name is" do
    assert Tools.call("nope", %{}, @closed) == {:error, :unknown_tool}
    assert Tools.call(123, %{}, @closed) == {:error, :unknown_tool}
  end

  describe "start_session" do
    test "returns the id of a live session" do
      assert {:ok, %{"isError" => false} = result} = Tools.call("start_session", %{}, @closed)
      session_id = text(result)
      on_exit(fn -> Mead.stop_session(session_id) end)

      assert {:ok, []} = Mead.history(session_id)
    end

    test "passes turn_timeout to the session" do
      {:ok, result} = Tools.call("start_session", %{"turn_timeout" => 1_234}, @closed)
      session_id = text(result)
      on_exit(fn -> Mead.stop_session(session_id) end)

      state = session_id |> Mead.Session.whereis(:server) |> :sys.get_state()
      assert state.turn_timeout == 1_234
    end

    test "refuses a turn_timeout that is not a positive integer within the limit" do
      for value <- [0, -1, "30", 1.5, nil, [], 4_294_967_296] do
        assert {:error, {:invalid_params, message}} =
                 Tools.call("start_session", %{"turn_timeout" => value}, @closed)

        assert message =~ "turn_timeout"
      end
    end
  end

  describe "submit_turn" do
    test "returns the reply of the turn" do
      session_id = start_session!()

      assert {:ok, %{"isError" => false} = result} = submit(session_id, "echo hello")
      assert text(result) == "hello"
    end

    test "an unknown session is a tool error, not a crash" do
      assert {:ok, %{"isError" => true} = result} = submit("no-such-session", "echo hi")
      assert text(result) == "unknown session"
    end

    test "refuses arguments of the wrong type as invalid params" do
      session_id = start_session!()

      for arguments <- [
            %{"session_id" => 123, "input" => "echo hi"},
            %{"input" => "echo hi"},
            %{"session_id" => session_id, "input" => 123},
            %{"session_id" => session_id},
            %{"session_id" => session_id, "input" => "echo hi", "route" => "sideways"},
            %{"session_id" => session_id, "input" => "echo hi", "route" => 5}
          ] do
        assert {:error, {:invalid_params, _message}} =
                 Tools.call("submit_turn", arguments, @closed)
      end

      assert {:ok, []} = Mead.history(session_id)
    end

    test "accepts an input of exactly 100 000 characters and refuses one more" do
      session_id = start_session!()
      body = String.duplicate("é", 100_000 - String.length("echo "))

      assert {:ok, %{"isError" => false}} = submit(session_id, "echo " <> body)

      assert {:error, {:invalid_params, message}} = submit(session_id, "echo " <> body <> "é")
      assert message =~ "100000"
      assert {:ok, [_only_the_first_turn]} = Mead.history(session_id)
    end

    test "the route reaches the handler, and auto is the default" do
      session_id = start_session!()

      {:ok, default} = submit(session_id, "options")
      assert text(default) =~ "route: :auto"
      refute text(default) =~ "tools:"

      for route <- ["auto", "local", "cloud"] do
        {:ok, result} = submit(session_id, "options", %{"route" => route})
        assert text(result) =~ "route: :#{route}"
      end
    end

    test "tools other than \"effect\" behave as if it were absent" do
      session_id = start_session!()

      for value <- ["read", "EFFECT", 5, nil, true, ["effect"]] do
        {:ok, result} = submit(session_id, "options", %{"tools" => value}, @open)
        refute text(result) =~ "tools:"
      end
    end

    test "effect tools need both the operator and the turn" do
      session_id = start_session!()

      {:ok, closed} = submit(session_id, "options", %{"tools" => "effect"}, @closed)
      assert closed["isError"] == true
      assert text(closed) =~ "not enabled by the operator"
      assert {:ok, []} = Mead.history(session_id)

      {:ok, open} = submit(session_id, "options", %{"tools" => "effect"}, @open)
      assert open["isError"] == false
      assert text(open) =~ "tools: :effect"
    end

    test "a failed turn gives a fixed message and none of the internal reason" do
      session_id = start_session!()

      for input <- ["raise", "error"] do
        assert {:ok, %{"isError" => true} = result} = submit(session_id, input)
        assert text(result) == "the turn failed"
      end
    end

    test "a turn that outlives the session's timeout is a tool error" do
      session_id = start_session!(turn_timeout: 50)

      assert {:ok, %{"isError" => true} = result} = submit(session_id, "block")
      assert text(result) == "the turn timed out"
    end

    test "an output that is not valid UTF-8 still encodes as a text result" do
      session_id = start_session!()

      assert {:ok, %{"isError" => false} = result} = submit(session_id, "binary")
      assert String.valid?(text(result))
      assert is_binary(JSON.encode!(result))
    end

    test "an output that is not a string is shown as text" do
      session_id = start_session!(handler: NonStringHandler)

      assert {:ok, %{"isError" => false} = result} = submit(session_id, "anything")
      assert text(result) =~ "reply"
    end

    test "a second turn while one is running is a tool error" do
      session_id = start_session!()
      Process.register(self(), :mcp_text_handler_test)
      task = Task.async(fn -> submit(session_id, "block") end)
      assert_receive {:handler_started, handler}, 1_000

      assert {:ok, %{"isError" => true} = result} = submit(session_id, "echo hi")
      assert text(result) == "a turn is already running in this session"

      send(handler, :release)
      assert {:ok, %{"isError" => false}} = Task.await(task)
    end

    test "a caller that goes away does not abort the turn, and the turn is recorded" do
      session_id = start_session!()
      Process.register(self(), :mcp_text_handler_test)
      caller = spawn(fn -> submit(session_id, "block") end)
      assert_receive {:handler_started, handler}, 1_000

      Process.exit(caller, :kill)
      send(handler, :release)

      assert wait_until(fn ->
               match?({:ok, [%{status: :ok, output: "released"}]}, Mead.history(session_id))
             end)
    end
  end

  describe "history" do
    test "lists the turns as JSON text" do
      session_id = start_session!()
      {:ok, _result} = submit(session_id, "echo hi")

      assert {:ok, %{"isError" => false} = result} =
               Tools.call("history", %{"session_id" => session_id}, @closed)

      assert [turn] = JSON.decode!(text(result))
      assert turn["input"] == "echo hi"
      assert turn["output"] == "hi"
      assert turn["status"] == "ok"
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(turn["started_at"])
    end

    test "an empty session has an empty history" do
      session_id = start_session!()

      {:ok, result} = Tools.call("history", %{"session_id" => session_id}, @closed)

      assert JSON.decode!(text(result)) == []
    end

    test "a turn that failed shows its status and no internal reason" do
      session_id = start_session!()
      {:ok, _result} = submit(session_id, "raise")
      {:ok, _result} = submit(session_id, "error")

      {:ok, result} = Tools.call("history", %{"session_id" => session_id}, @closed)

      assert [%{"status" => "failed", "output" => nil}, %{"status" => "failed", "output" => nil}] =
               JSON.decode!(text(result))
    end

    test "an unknown session is a tool error and a non-string id is invalid params" do
      assert {:ok, %{"isError" => true}} =
               Tools.call("history", %{"session_id" => "no-such-session"}, @closed)

      assert {:error, {:invalid_params, _message}} =
               Tools.call("history", %{"session_id" => 7}, @closed)
    end
  end

  describe "stop_session" do
    test "stops the session, and stopping it again is a tool error" do
      session_id = start_session!()

      assert {:ok, %{"isError" => false} = result} =
               Tools.call("stop_session", %{"session_id" => session_id}, @closed)

      assert text(result) == "stopped"
      assert {:error, :not_found} = Mead.history(session_id)

      assert {:ok, %{"isError" => true} = again} =
               Tools.call("stop_session", %{"session_id" => session_id}, @closed)

      assert text(again) == "unknown session"
    end

    test "a non-string id is invalid params" do
      assert {:error, {:invalid_params, _message}} =
               Tools.call("stop_session", %{"session_id" => nil}, @closed)
    end
  end
end
