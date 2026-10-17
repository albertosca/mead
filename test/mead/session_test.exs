defmodule Mead.SessionTest do
  use ExUnit.Case, async: true

  test "whereis/2 returns nil for an unknown session" do
    assert Mead.Session.whereis(Mead.UUID.generate(), :server) == nil
  end

  test "whereis/2 resolves a process registered through via/2" do
    session_id = Mead.UUID.generate()
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: Mead.Session.via(session_id, :history))

    assert Mead.Session.whereis(session_id, :history) == pid
    assert Mead.Session.whereis(session_id, :server) == nil
  end
end
