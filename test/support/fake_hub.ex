defmodule Mead.Test.FakeHub do
  @moduledoc false

  # A stand-in for Mead.MCP.Hub that runs in the calling process, so a test sets the visible tools
  # and the result of each tool with `configure/1` and reads what the router did from the messages
  # it sends to `:test_pid`. Only for tests that call `Mead.Router.route/5` directly.

  def configure(settings), do: Process.put(__MODULE__, Map.new(settings))

  def tools_for(options) do
    settings = settings()
    send(settings.test_pid, {:tools_requested, options})
    Map.get(settings, :tools, [])
  end

  def call_tool(name, arguments, options) do
    settings = settings()
    send(settings.test_pid, {:tool_called, name, arguments, options})
    Map.get(settings.results, name, {:error, :unknown_tool})
  end

  # The class of a tool defaults to :read; `classes: %{"server__tool" => :effect}` overrides it. A
  # name with no configured result is unknown, as it is for call_tool/3.
  def describe_tool(name, _options) do
    settings = settings()

    if Map.has_key?(settings.results, name) do
      [server, tool] = String.split(name, "__", parts: 2)
      class = settings |> Map.get(:classes, %{}) |> Map.get(name, :read)
      {:ok, %{server: String.to_atom(server), tool: tool, class: class}}
    else
      {:error, :unknown_tool}
    end
  end

  defp settings, do: Process.get(__MODULE__)
end
