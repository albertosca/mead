defmodule Mead.MCP.Server.ToolsPersistenceTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.MCP.Server.Tools
  alias Mead.Session.Store

  @moduletag :tmp_dir
  @closed %{allow_effect: false}

  setup %{tmp_dir: directory} do
    previous = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    %{directory: directory}
  end

  defp call(name, arguments), do: Tools.call(name, arguments, @closed)

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  defp start_and_stop_a_session do
    {:ok, started} = call("start_session", %{})
    session_id = text(started)
    on_exit(fn -> Mead.stop_session(session_id) end)
    {:ok, _result} = call("submit_turn", %{"session_id" => session_id, "input" => "hello"})
    {:ok, _result} = call("stop_session", %{"session_id" => session_id})
    session_id
  end

  test "the server offers six tools, the new ones last" do
    assert Enum.map(Tools.definitions(), & &1["name"]) ==
             [
               "start_session",
               "submit_turn",
               "history",
               "stop_session",
               "resume_session",
               "delete_session"
             ]

    resume = Enum.find(Tools.definitions(), &(&1["name"] == "resume_session"))
    assert resume["inputSchema"]["required"] == ["session_id"]
    assert resume["inputSchema"]["properties"]["turn_timeout"]["type"] == "integer"
  end

  test "stop_session leaves the conversation resumable through the same tools" do
    session_id = start_and_stop_a_session()

    assert {:ok, %{"isError" => true} = unknown} = call("history", %{"session_id" => session_id})
    assert text(unknown) == "unknown session"

    assert {:ok, %{"isError" => false} = resumed} =
             call("resume_session", %{"session_id" => session_id})

    assert text(resumed) == session_id

    assert {:ok, %{"isError" => false} = history} = call("history", %{"session_id" => session_id})
    assert [%{"input" => "hello", "status" => "ok"}] = JSON.decode!(text(history))
  end

  test "resume_session answers the failures with fixed messages", %{directory: directory} do
    running = start_and_stop_a_session()
    {:ok, _result} = call("resume_session", %{"session_id" => running})

    assert {:ok, %{"isError" => true} = already} =
             call("resume_session", %{"session_id" => running})

    assert text(already) == "the session is already running"

    assert {:ok, %{"isError" => true} = unknown} =
             call("resume_session", %{"session_id" => Mead.UUID.generate()})

    assert text(unknown) == "unknown session"

    assert {:ok, %{"isError" => true} = traversal} =
             call("resume_session", %{"session_id" => "../x"})

    assert text(traversal) == "unknown session"

    damaged = Mead.UUID.generate()

    File.write!(
      Path.join(directory, damaged <> ".log"),
      <<0, 0, 0, 5, 0, 0, 0, 0, 1, 2, 3, 4, 5, 9>>
    )

    assert {:ok, %{"isError" => true} = corrupt} =
             call("resume_session", %{"session_id" => damaged})

    assert text(corrupt) == "the stored conversation is damaged"
  end

  test "resume_session validates its arguments as protocol errors" do
    assert {:error, {:invalid_params, _message}} = call("resume_session", %{})
    assert {:error, {:invalid_params, _message}} = call("resume_session", %{"session_id" => 7})

    assert {:error, {:invalid_params, _message}} =
             call("resume_session", %{"session_id" => Mead.UUID.generate(), "turn_timeout" => 0})
  end

  test "delete_session removes the conversation for good", %{directory: directory} do
    session_id = start_and_stop_a_session()
    assert Store.exists?(directory, session_id)

    assert {:ok, %{"isError" => false} = deleted} =
             call("delete_session", %{"session_id" => session_id})

    assert text(deleted) == "deleted"
    refute Store.exists?(directory, session_id)

    assert {:ok, %{"isError" => true} = again} =
             call("delete_session", %{"session_id" => session_id})

    assert text(again) == "unknown session"
    assert {:error, {:invalid_params, _message}} = call("delete_session", %{})
  end

  test "a turn that cannot be saved is reported as such" do
    Application.put_env(:mead, :storage, directory: "/dev/null/blocked")
    {:ok, started_blocked} = call("start_session", %{})
    blocked = text(started_blocked)
    on_exit(fn -> Mead.stop_session(blocked) end)

    assert {:ok, %{"isError" => true} = failure} =
             call("submit_turn", %{"session_id" => blocked, "input" => "hello"})

    assert text(failure) == "the conversation could not be saved"
  end
end
