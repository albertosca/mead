defmodule Mead.ResumeTest do
  # Sets the global :storage and :router settings and registers a global handler name, so it must
  # not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Ledger
  alias Mead.Session
  alias Mead.Session.Store
  alias Mead.Session.Turn
  alias Mead.Test.FakeProvider

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    previous_router = Application.fetch_env(:mead, :router)
    Application.put_env(:mead, :storage, directory: directory)

    Application.put_env(:mead, :router,
      slots: [
        local: nil,
        cloud:
          {FakeProvider,
           test_pid: self(), result: {:ok, %{text: "cloud reply", usage: FakeProvider.usage()}}}
      ]
    )

    on_exit(fn ->
      restore(:storage, previous_storage)
      restore(:router, previous_router)
    end)

    %{directory: directory}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:mead, key, value)
  defp restore(key, :error), do: Application.delete_env(:mead, key)

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  defp file_of(directory, session_id), do: Path.join(directory, session_id <> ".log")

  defp start_text_session do
    {:ok, session_id} = Mead.start_session(handler: Mead.Test.TextHandler)
    on_exit(fn -> Mead.stop_session(session_id) end)
    session_id
  end

  describe "resume_session/2" do
    test "rebuilds a stopped session with the same id and turns, and keeps appending to its file",
         %{directory: directory} do
      session_id = start_text_session()
      assert Mead.submit_turn(session_id, "echo one") == {:ok, "one"}
      assert Mead.submit_turn(session_id, "echo two") == {:ok, "two"}
      {:ok, earlier} = Mead.history(session_id)

      assert Mead.stop_session(session_id) == :ok
      assert Mead.history(session_id) == {:error, :not_found}
      assert File.exists?(file_of(directory, session_id))

      assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) == {:ok, session_id}
      assert Mead.history(session_id) == {:ok, earlier}

      assert Mead.submit_turn(session_id, "echo three") == {:ok, "three"}
      assert {:ok, [_one, _two, %Turn{input: "echo three"}]} = Store.load(directory, session_id)
      assert {:ok, stored} = Store.load(directory, session_id)
      assert {:ok, ^stored} = Mead.history(session_id)
    end

    test "a turn left in progress comes back interrupted, and a second resume changes nothing",
         %{directory: directory} do
      session_id = Mead.UUID.generate()
      :ok = Store.append(directory, session_id, {:append, Turn.start("lost")})

      assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) == {:ok, session_id}
      on_exit(fn -> Mead.stop_session(session_id) end)
      assert {:ok, [%Turn{input: "lost", status: :interrupted}]} = Mead.history(session_id)

      assert Mead.stop_session(session_id) == :ok
      written = File.read!(file_of(directory, session_id))

      assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) == {:ok, session_id}
      assert {:ok, [%Turn{status: :interrupted}]} = Mead.history(session_id)
      assert File.read!(file_of(directory, session_id)) == written
    end

    test "a running session cannot be resumed" do
      session_id = start_text_session()

      assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) ==
               {:error, :already_running}
    end

    test "an unknown id and ids that are not session ids are :not_found and start nothing",
         %{directory: directory} do
      ids = [
        Mead.UUID.generate(),
        "../x",
        "/etc/passwd",
        "",
        String.upcase(Mead.UUID.generate()),
        String.duplicate("a", 10_000)
      ]

      for id <- ids do
        assert Mead.resume_session(id) == {:error, :not_found}
        assert Session.whereis(id, :supervisor) == nil
      end

      assert File.ls!(directory) == []
    end

    test "a damaged file is :corrupt_history and starts no process", %{directory: directory} do
      session_id = Mead.UUID.generate()
      :ok = Store.append(directory, session_id, {:append, Turn.start("a")})
      :ok = Store.append(directory, session_id, {:append, Turn.start("b")})
      <<head::binary-size(20), byte, tail::binary>> = File.read!(file_of(directory, session_id))

      File.write!(
        file_of(directory, session_id),
        <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>
      )

      assert Mead.resume_session(session_id) == {:error, :corrupt_history}
      assert Session.whereis(session_id, :supervisor) == nil
    end

    test "a torn tail is cut off, so a turn after the resume survives another resume",
         %{directory: directory} do
      session_id = start_text_session()
      assert Mead.submit_turn(session_id, "echo one") == {:ok, "one"}
      Mead.stop_session(session_id)
      File.write!(file_of(directory, session_id), <<0, 0, 0, 9, 1>>, [:append])

      ExUnit.CaptureLog.capture_log(fn ->
        assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) ==
                 {:ok, session_id}
      end)

      assert Mead.submit_turn(session_id, "echo two") == {:ok, "two"}
      Mead.stop_session(session_id)

      assert Mead.resume_session(session_id, handler: Mead.Test.TextHandler) == {:ok, session_id}

      assert {:ok, [%Turn{input: "echo one"}, %Turn{input: "echo two"}]} =
               Mead.history(session_id)
    end

    test "a history that restarts after a crash reloads what is on disk, not the resume snapshot" do
      session_id = start_text_session()
      Mead.submit_turn(session_id, "echo one")
      Mead.stop_session(session_id)
      {:ok, ^session_id} = Mead.resume_session(session_id, handler: Mead.Test.TextHandler)
      assert Mead.submit_turn(session_id, "echo two") == {:ok, "two"}

      history = Session.whereis(session_id, :history)
      Process.exit(history, :kill)

      assert eventually(fn ->
               match?({:ok, [%Turn{}, %Turn{input: "echo two"}]}, Mead.history(session_id))
             end)
    end

    test "without a storage directory nothing can be resumed" do
      Application.delete_env(:mead, :storage)

      assert Mead.resume_session(Mead.UUID.generate()) == {:error, :not_found}
    end

    test "rejects options the way start_session/1 does" do
      assert_raise ArgumentError, fn -> Mead.resume_session(Mead.UUID.generate(), bogus: 1) end
    end
  end

  describe "resume and delete at the same time" do
    test "never leave a running session without its file", %{directory: directory} do
      for _round <- 1..40 do
        session_id = start_text_session()
        Mead.submit_turn(session_id, "echo hi")
        Mead.stop_session(session_id)

        tasks = [
          Task.async(fn -> Mead.resume_session(session_id, handler: Mead.Test.TextHandler) end),
          Task.async(fn -> Mead.delete_session(session_id) end)
        ]

        Task.await_many(tasks)

        running = Session.whereis(session_id, :supervisor) != nil
        refute running and not Store.exists?(directory, session_id)
        Mead.stop_session(session_id)
      end
    end
  end

  describe "stop_session/1 and delete_session/1" do
    test "stop_session/1 keeps the file", %{directory: directory} do
      session_id = start_text_session()
      Mead.submit_turn(session_id, "echo hi")

      assert Mead.stop_session(session_id) == :ok
      assert Store.exists?(directory, session_id)
    end

    test "delete_session/1 removes the file and the ledger aggregate of a running session",
         %{directory: directory} do
      {:ok, session_id} = Mead.start_session(handler: Mead.Router)
      on_exit(fn -> Mead.stop_session(session_id) end)
      assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")
      assert {:ok, %{turns: 1}} = Ledger.session_totals(session_id)

      assert Mead.delete_session(session_id) == :ok
      assert Session.whereis(session_id, :supervisor) == nil
      refute Store.exists?(directory, session_id)
      assert Ledger.session_totals(session_id) == {:error, :not_found}
    end

    test "delete_session/1 removes the file of a session that is not running",
         %{directory: directory} do
      session_id = start_text_session()
      Mead.submit_turn(session_id, "echo hi")
      Mead.stop_session(session_id)

      assert Mead.delete_session(session_id) == :ok
      refute Store.exists?(directory, session_id)
      assert Mead.resume_session(session_id) == {:error, :not_found}
    end

    test "delete_session/1 forgets the ledger aggregate even when the file cannot be removed",
         %{directory: directory} do
      {:ok, session_id} = Mead.start_session(handler: Mead.Router)

      on_exit(fn ->
        File.chmod(directory, 0o755)
        Mead.stop_session(session_id)
      end)

      assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")
      File.chmod!(directory, 0o000)

      assert Mead.delete_session(session_id) == {:error, {:persistence, :eacces}}
      assert Ledger.session_totals(session_id) == {:error, :not_found}
    end

    test "start_session/1 raises on a malformed storage setting" do
      Application.put_env(:mead, :storage, "not a keyword list")

      assert_raise ArgumentError, ~r/must be a keyword list/, fn -> Mead.start_session() end
    end

    test "delete_session/1 is :not_found when there was neither a process nor a file" do
      assert Mead.delete_session(Mead.UUID.generate()) == {:error, :not_found}
      assert Mead.delete_session("../x") == {:error, :not_found}
    end

    test "delete_session/1 works without a storage directory" do
      Application.delete_env(:mead, :storage)
      {:ok, session_id} = Mead.start_session(handler: Mead.Test.TextHandler)

      assert Mead.delete_session(session_id) == :ok
      assert Mead.delete_session(session_id) == {:error, :not_found}
    end
  end
end
