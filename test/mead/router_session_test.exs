defmodule Mead.RouterSessionTest do
  # Reads the application environment, which is global, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Test.FakeProvider

  setup do
    previous = Application.fetch_env(:mead, :router)

    Application.put_env(:mead, :router,
      slots: [
        local: nil,
        cloud:
          {FakeProvider,
           test_pid: self(), result: {:ok, %{text: "cloud reply", usage: FakeProvider.usage()}}}
      ]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :router, value)
        :error -> Application.delete_env(:mead, :router)
      end
    end)

    {:ok, session_id} = Mead.start_session(handler: Mead.Router)
    on_exit(fn -> Mead.stop_session(session_id) end)

    %{session_id: session_id}
  end

  test "a session routes a turn to the cloud slot and records the reply", %{
    session_id: session_id
  } do
    assert Mead.submit_turn(session_id, "explain this") == {:ok, "cloud reply"}
    assert {:ok, [%{status: :ok, output: "cloud reply"}]} = Mead.history(session_id)
  end

  test "a turn for the empty local slot fails with a reason the caller can see", %{
    session_id: session_id
  } do
    assert Mead.submit_turn(session_id, "list my tasks") ==
             {:error, {:failed, :local_unavailable}}

    assert Mead.submit_turn(session_id, "list my tasks", route: :cloud) == {:ok, "cloud reply"}
  end
end
