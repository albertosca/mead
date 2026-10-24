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
