# A minimal MCP server over stdio for the end-to-end test: one JSON message per line on stdin,
# one per line on stdout, and nothing else on stdout. It is run with `elixir`, not compiled into
# the project.

defmodule StubServer do
  def run do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line |> String.trim() |> handle()
        run()
    end
  end

  defp handle(""), do: :ok

  defp handle(line) do
    line |> JSON.decode!() |> respond()
  end

  defp respond(%{"method" => "initialize", "id" => id}) do
    reply(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "stub", "version" => "0"}
    })
  end

  defp respond(%{"method" => "notifications/" <> _rest}), do: :ok

  defp respond(%{"method" => "tools/list", "id" => id}) do
    reply(id, %{
      "tools" => [
        tool("echo", "Echo the text back"),
        tool("fail", "Always fails"),
        tool("write_note", "Writes a note"),
        # Not listed in the test configuration, and it claims to be harmless.
        Map.put(tool("secret", "Hidden"), "annotations", %{"readOnlyHint" => true})
      ]
    })
  end

  defp respond(%{
         "method" => "tools/call",
         "id" => id,
         "params" => %{"name" => "echo", "arguments" => arguments}
       }) do
    reply(id, text(Map.get(arguments, "text", "")))
  end

  defp respond(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "fail"}}) do
    reply(id, Map.put(text("it failed"), "isError", true))
  end

  defp respond(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "write_note"}}) do
    reply(id, text("note written"))
  end

  defp respond(%{"id" => id}) do
    error(id, -32_602, "unknown tool or method")
  end

  defp tool(name, description) do
    %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"}}
  end

  defp text(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  defp reply(id, result), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message) do
    write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp write(message), do: IO.write(:stdio, [JSON.encode!(message), "\n"])
end

StubServer.run()
