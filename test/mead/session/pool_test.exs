defmodule Mead.Session.PoolTest do
  use ExUnit.Case, async: true

  alias Mead.Session.Pool

  defp start_pool(options) do
    name = :"pool_#{System.unique_integer([:positive])}"
    start_supervised!({Pool, [name: name] ++ options})
    name
  end

  defp session_options,
    do: [session_id: Mead.UUID.generate(), handler: Mead.Session.EchoHandler, turn_timeout: 1_000]

  test "refuses a session beyond maximum_sessions, and accepts one again once a session is gone" do
    pool = start_pool(maximum_sessions: 2)

    {:ok, first} = Pool.start_session(session_options(), pool)
    {:ok, _second} = Pool.start_session(session_options(), pool)

    assert Pool.start_session(session_options(), pool) == {:error, :max_children}

    :ok = DynamicSupervisor.terminate_child(pool, first)
    assert {:ok, _third} = Pool.start_session(session_options(), pool)
  end

  test "the id is free again the moment stop_session returns" do
    for _attempt <- 1..300 do
      {:ok, session_id} = Mead.start_session()

      assert Pool.stop_session(session_id) == :ok
      assert Mead.Session.whereis(session_id, :supervisor) == nil
      assert Mead.Session.whereis(session_id, :server) == nil
    end
  end
end
