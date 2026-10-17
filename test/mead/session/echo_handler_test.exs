defmodule Mead.Session.EchoHandlerTest do
  use ExUnit.Case, async: true

  test "handle_turn/2 returns the input as the output" do
    assert Mead.Session.EchoHandler.handle_turn([], "hello") == {:ok, "hello"}
  end
end
