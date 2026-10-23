defmodule Mead.MCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.Transport.Stdio

  defp start(options) do
    {:ok, transport} = Stdio.start_link(options, self())
    transport
  end

  defp shell(script, extra \\ []), do: [command: "sh", arguments: ["-c", script]] ++ extra

  defp alive?(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
  end

  test "delivers each line the child prints as one message, in order" do
    transport = start(shell("echo first; echo second"))

    assert_receive {:mcp_message, ^transport, "first"}, 10_000
    assert_receive {:mcp_message, ^transport, "second"}, 10_000
    assert_receive {:mcp_closed, ^transport, {:exit_status, 0}}, 10_000
  end

  test "skips blank lines" do
    transport = start(shell("printf 'one\\n\\ntwo\\n'"))

    assert_receive {:mcp_message, ^transport, "one"}, 10_000
    assert_receive {:mcp_message, ^transport, "two"}, 10_000
    refute_received {:mcp_message, ^transport, ""}
  end

  test "writes a message to the child's stdin followed by a newline" do
    transport = start(command: "cat")

    assert :ok = Stdio.send_message(transport, 1, ~s({"jsonrpc":"2.0","id":1}))
    assert_receive {:mcp_message, ^transport, ~s({"jsonrpc":"2.0","id":1})}, 10_000
  end

  test "reassembles a line longer than the port buffer into one message" do
    transport = start(shell("yes a | head -c 100000 | tr -d '\\n'; echo"))

    assert_receive {:mcp_message, ^transport, message}, 5_000
    assert message == String.duplicate("a", 50_000)
  end

  test "closes with :message_too_large when one message passes the limit" do
    transport =
      start(shell("yes a | head -c 100000 | tr -d '\\n'; echo", maximum_message_bytes: 1_000))

    assert_receive {:mcp_closed, ^transport, :message_too_large}, 5_000
    refute_received {:mcp_message, ^transport, _message}
  end

  test "reports the exit status when the child leaves" do
    transport = start(shell("exit 3"))

    assert_receive {:mcp_closed, ^transport, {:exit_status, 3}}, 10_000
  end

  test "a command that does not exist is an error, not a crash" do
    assert Stdio.start_link([command: "definitely-not-a-command-xyz"], self()) ==
             {:error, {:command_not_found, "definitely-not-a-command-xyz"}}
  end

  test "a missing or empty command is refused" do
    assert Stdio.start_link([], self()) == {:error, :invalid_command}
    assert Stdio.start_link([command: ""], self()) == {:error, :invalid_command}
    assert Stdio.start_link([command: 123], self()) == {:error, :invalid_command}
  end

  test "sending after the child is gone is an error, not a crash" do
    transport = start(shell("exit 0"))
    assert_receive {:mcp_closed, ^transport, {:exit_status, 0}}, 10_000

    wait_until(fn -> not Process.alive?(transport) end)

    assert Stdio.send_message(transport, 1, "{}") == {:error, :closed}
  end

  describe "the child process does not outlive the transport" do
    # `exec sleep` ignores stdin closing, so only the signals can end it, and the child's pid is
    # the first line it prints.
    test "stopping the transport ends a child that ignores stdin closing" do
      transport = start(shell("echo $$; exec sleep 30", exit_grace_milliseconds: 50))
      assert_receive {:mcp_message, ^transport, os_pid}, 10_000
      assert alive?(os_pid)

      GenServer.stop(transport)

      wait_until(fn -> not alive?(os_pid) end, 3_000)
    end

    test "killing the owner ends the child too" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, transport} =
            Stdio.start_link(shell("echo $$; exec sleep 30", exit_grace_milliseconds: 50), self())

          receive do
            {:mcp_message, ^transport, os_pid} -> send(test_pid, {:child, os_pid})
          end

          Process.sleep(:infinity)
        end)

      assert_receive {:child, os_pid}, 10_000
      assert alive?(os_pid)

      Process.exit(owner, :kill)

      wait_until(fn -> not alive?(os_pid) end, 3_000)
    end

    test "a child that closes when stdin closes is not signalled" do
      transport = start(command: "cat")
      Stdio.send_message(transport, 1, "ping")
      assert_receive {:mcp_message, ^transport, "ping"}, 10_000

      started = System.monotonic_time(:millisecond)
      GenServer.stop(transport)

      assert System.monotonic_time(:millisecond) - started < 900
    end
  end
end
