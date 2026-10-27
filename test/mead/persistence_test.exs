defmodule Mead.PersistenceTest do
  # Registers a global name for the blocking handler, and later changes the global :storage
  # setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mead.Session.Pool
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    Process.register(self(), :mcp_text_handler_test)
    %{directory: directory}
  end

  defp start_session(directory) do
    session_id = Mead.UUID.generate()

    {:ok, _pid} =
      Pool.start_session(
        session_id: session_id,
        handler: Mead.Test.TextHandler,
        turn_timeout: 5_000,
        directory: directory
      )

    session_id
  end

  defp file_of(directory, session_id), do: Path.join(directory, session_id <> ".log")

  describe "a session with a storage directory" do
    test "records a finished turn with its output", %{directory: directory} do
      session_id = start_session(directory)

      assert Mead.submit_turn(session_id, "echo hi") == {:ok, "hi"}

      assert {:ok, [%Turn{input: "echo hi", status: :ok, output: "hi"}]} =
               Store.load(directory, session_id)
    end

    test "has the turn on disk while the handler is still running", %{directory: directory} do
      session_id = start_session(directory)
      task = Task.async(fn -> Mead.submit_turn(session_id, "block") end)

      assert_receive {:handler_started, handler}

      assert {:ok, [%Turn{input: "block", status: :in_progress}]} =
               Store.load(directory, session_id)

      send(handler, :release)
      assert Task.await(task) == {:ok, "released"}
      assert {:ok, [%Turn{status: :ok}]} = Store.load(directory, session_id)
    end

    test "refuses a turn it cannot record and never starts the handler", %{directory: directory} do
      blocker = Path.join(directory, "blocker")
      File.write!(blocker, "")
      session_id = start_session(Path.join(blocker, "inside"))

      assert Mead.submit_turn(session_id, "block") == {:error, {:persistence, :enotdir}}
      refute_receive {:handler_started, _handler}, 100
      assert Mead.history(session_id) == {:ok, []}
    end

    test "keeps the reply when only the end of the turn cannot be recorded", %{
      directory: directory
    } do
      session_id = start_session(directory)
      task = Task.async(fn -> Mead.submit_turn(session_id, "block") end)

      assert_receive {:handler_started, handler}
      File.chmod!(file_of(directory, session_id), 0o400)

      # The release is inside the capture: the server logs the failed write as soon as the
      # handler is released, which can be before a capture that starts afterwards.
      log =
        capture_log(fn ->
          send(handler, :release)
          assert Task.await(task) == {:ok, "released"}
        end)

      assert log =~ "could not record the history"
      assert {:ok, [%Turn{status: :ok, output: "released"}]} = Mead.history(session_id)
    end
  end
end
