defmodule Mead.Provider.OllamaTest do
  use ExUnit.Case, async: true

  alias Mead.Provider.Ollama

  @moduletag :capture_log

  @messages [%{role: :user, content: "hello"}]

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
end
