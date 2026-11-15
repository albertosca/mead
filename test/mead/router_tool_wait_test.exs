defmodule Mead.RouterToolWaitTest do
  # Changes the application environment, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Router

  setup do
    previous = Application.get_env(:mead, :mcp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mead, :mcp, previous),
        else: Application.delete_env(:mead, :mcp)
    end)
  end

  test "the router waits five seconds longer than the default hub deadline" do
    Application.delete_env(:mead, :mcp)

    assert Router.tool_wait() == 20_000
  end

  test "a raised hub deadline raises the wait around it, so the router never cuts a call first" do
    Application.put_env(:mead, :mcp, tool_timeout: 240_000)

    assert Router.tool_wait() == 245_000
  end
end
