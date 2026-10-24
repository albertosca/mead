defmodule Mead.MCP.Transport.HttpTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Transport.Http

  @sentinel_header_value "Bearer SENTINEL-0123456789"
  @response ~s({"jsonrpc":"2.0","id":1,"result":{}})

  # The plug is an ordinary function, so it runs in the process that makes the request and needs
  # no `Req.Test` ownership; it reports what it saw to the test process.
  defp start(plug, extra \\ []) do
    options = [url: "http://mcp.test/mcp", req_options: [plug: plug]] ++ extra

    start_supervised!(%{id: make_ref(), start: {Http, :start_link, [options, self()]}})
  end

  defp json(conn, body) do
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, body)
  end

  defp event_stream(conn, body) do
    conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
  end

  test "delivers a JSON answer as one message" do
    transport = start(&json(&1, @response))

    assert :ok = Http.send_message(transport, 1, "{}")
    assert_receive {:mcp_message, ^transport, @response}, 10_000
  end

  test "delivers each event of an event stream, joining the data lines of one event" do
    body =
      "event: message\ndata: {\"id\":1}\n\n" <>
        ": a comment\n\n" <>
        "event: message\r\ndata: {\"a\":\r\ndata: 2}\r\n\r\n"

    transport = start(&event_stream(&1, body))

    Http.send_message(transport, 1, "{}")

    assert_receive {:mcp_message, ^transport, ~s({"id":1})}, 10_000
    assert_receive {:mcp_message, ^transport, "{\"a\":\n2}"}, 10_000
    refute_received {:mcp_message, ^transport, _other}
  end

  test "an accepted notification delivers nothing and fails nothing" do
    transport = start(&Plug.Conn.send_resp(&1, 202, ""))

    assert :ok = Http.send_message(transport, nil, "{}")

    refute_receive {:mcp_message, ^transport, _message}, 200
    refute_received {:mcp_send_failed, ^transport, _id, _reason}
  end

  test "posts the message with the JSON content type, the accept header, and the protocol version" do
    test_pid = self()

    transport =
      start(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.method, conn.req_headers, body})
        json(conn, @response)
      end)

    Http.send_message(transport, 1, ~s({"jsonrpc":"2.0","id":1}))

    assert_receive {:request, "POST", headers, ~s({"jsonrpc":"2.0","id":1})}, 10_000
    assert {"content-type", "application/json"} in headers
    assert {"accept", "application/json, text/event-stream"} in headers
    assert {"mcp-protocol-version", "2025-06-18"} in headers
  end

  test "sends the configured headers" do
    test_pid = self()

    transport =
      start(
        fn conn ->
          send(test_pid, {:headers, conn.req_headers})
          json(conn, @response)
        end,
        headers: [{"authorization", @sentinel_header_value}]
      )

    Http.send_message(transport, 1, "{}")

    assert_receive {:headers, headers}, 10_000
    assert {"authorization", @sentinel_header_value} in headers
  end

  test "echoes the session id the server assigned on every later request" do
    test_pid = self()

    transport =
      start(fn conn ->
        send(test_pid, {:session_header, Plug.Conn.get_req_header(conn, "mcp-session-id")})

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "session-1")
        |> json(@response)
      end)

    Http.send_message(transport, 1, "{}")
    assert_receive {:session_header, []}, 10_000
    assert_receive {:mcp_message, ^transport, _message}, 10_000

    Http.send_message(transport, 2, "{}")
    assert_receive {:session_header, ["session-1"]}, 10_000
  end

  describe "failures reach the owner as a send failure for that request id" do
    test "a non-success status" do
      transport = start(&Plug.Conn.send_resp(&1, 500, "boom"))

      Http.send_message(transport, 5, "{}")

      assert_receive {:mcp_send_failed, ^transport, 5, {:http_status, 500}}, 10_000
    end

    test "a refused connection" do
      transport = start(&Req.Test.transport_error(&1, :econnrefused))

      Http.send_message(transport, 6, "{}")

      assert_receive {:mcp_send_failed, ^transport, 6, {:transport, :econnrefused}}, 10_000
    end

    test "a timeout" do
      transport = start(&Req.Test.transport_error(&1, :timeout))

      Http.send_message(transport, 7, "{}")

      assert_receive {:mcp_send_failed, ^transport, 7, :timeout}, 10_000
    end

    test "an answer that is neither JSON nor an event stream" do
      transport =
        start(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, "<html>")
        end)

      Http.send_message(transport, 8, "{}")

      assert_receive {:mcp_send_failed, ^transport, 8,
                      {:unexpected_content_type, "text/html" <> _}},
                     10_000
    end

    test "a failed notification reports a nil id" do
      transport = start(&Plug.Conn.send_resp(&1, 503, ""))

      Http.send_message(transport, nil, "{}")

      assert_receive {:mcp_send_failed, ^transport, nil, {:http_status, 503}}, 10_000
    end

    test "no reason contains a configured header value" do
      transport =
        start(&Plug.Conn.send_resp(&1, 401, "denied"),
          headers: [{"authorization", @sentinel_header_value}]
        )

      Http.send_message(transport, 9, "{}")

      assert_receive {:mcp_send_failed, ^transport, 9, reason}, 10_000
      refute inspect(reason) =~ "SENTINEL"
    end
  end

  describe "a response larger than the limit" do
    test "is refused as a send failure, whether JSON or an event stream" do
      oversized = String.duplicate("x", 4 * 1024 * 1024 + 1)

      json_transport = start(&json(&1, oversized))
      Http.send_message(json_transport, 21, "{}")
      assert_receive {:mcp_send_failed, ^json_transport, 21, :response_too_large}, 10_000
      refute_received {:mcp_message, ^json_transport, _message}

      stream_transport = start(&event_stream(&1, "data: " <> oversized <> "\n\n"))
      Http.send_message(stream_transport, 22, "{}")
      assert_receive {:mcp_send_failed, ^stream_transport, 22, :response_too_large}, 10_000
      refute_received {:mcp_message, ^stream_transport, _message}
    end

    test "leaves the transport able to carry the next request" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      transport =
        start(fn conn ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> json(conn, String.duplicate("x", 4 * 1024 * 1024 + 1))
            _later -> json(conn, @response)
          end
        end)

      Http.send_message(transport, 1, "{}")
      assert_receive {:mcp_send_failed, ^transport, 1, :response_too_large}, 10_000

      Http.send_message(transport, 2, "{}")
      assert_receive {:mcp_message, ^transport, @response}, 10_000
    end
  end

  describe "a 404" do
    test "after a session was assigned means the session expired and closes the transport" do
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      transport =
        start(fn conn ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 ->
              conn |> Plug.Conn.put_resp_header("mcp-session-id", "session-1") |> json(@response)

            _later ->
              send(test_pid, :second_request_made)
              Plug.Conn.send_resp(conn, 404, "")
          end
        end)

      Http.send_message(transport, 1, "{}")
      assert_receive {:mcp_message, ^transport, _message}, 10_000

      Http.send_message(transport, 2, "{}")

      assert_receive :second_request_made, 10_000
      assert_receive {:mcp_closed, ^transport, :session_expired}, 10_000
    end

    test "without a session is an ordinary status failure" do
      transport = start(&Plug.Conn.send_resp(&1, 404, ""))

      Http.send_message(transport, 3, "{}")

      assert_receive {:mcp_send_failed, ^transport, 3, {:http_status, 404}}, 10_000
      refute_received {:mcp_closed, ^transport, _reason}
    end
  end

  test "a url that is not http or https is refused" do
    assert Http.start_link([url: "ftp://example.test"], self()) == {:error, :invalid_url}
    assert Http.start_link([url: 123], self()) == {:error, :invalid_url}
    assert Http.start_link([], self()) == {:error, :invalid_url}
  end

  test "sending to a transport that is gone is an error, not a crash" do
    # Started without a supervisor, which would restart the transport after the kill.
    {:ok, transport} =
      Http.start_link(
        [url: "http://mcp.test/mcp", req_options: [plug: &json(&1, @response)]],
        self()
      )

    Process.unlink(transport)
    monitor = Process.monitor(transport)
    Process.exit(transport, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^transport, _reason}, 10_000

    assert Http.send_message(transport, 1, "{}") == {:error, :closed}
  end

  test "the state shown in crash reports never carries the configured headers" do
    transport =
      start(&json(&1, @response), headers: [{"authorization", @sentinel_header_value}])

    status =
      transport |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

    refute status =~ "SENTINEL-0123456789"
  end
end
