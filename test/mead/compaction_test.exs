defmodule Mead.CompactionTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mead.Session.Store

  @moduletag :tmp_dir

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

  defp file_of(directory, session_id), do: Path.join(directory, session_id <> ".log")

  defp session_with_turns(count) do
    {:ok, session_id} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(session_id) end)

    for index <- 1..count do
      {:ok, _output} = Mead.submit_turn(session_id, "question #{index}")
    end

    session_id
  end

  test "resume keeps only the newest max_turns turns when the setting is on", %{
    directory: directory
  } do
    session_id = session_with_turns(8)
    Mead.stop_session(session_id)
    Application.put_env(:mead, :storage, directory: directory, max_turns: 3)

    assert {:ok, ^session_id} = Mead.resume_session(session_id)
    {:ok, history} = Mead.history(session_id)

    assert Enum.map(history, & &1.input) == ["question 6", "question 7", "question 8"]
    {:ok, stored} = Store.load(directory, session_id)
    assert Enum.map(stored, & &1.input) == ["question 6", "question 7", "question 8"]
  end

  test "compact_session on a stopped session applies max_turns too", %{directory: directory} do
    session_id = session_with_turns(8)
    Mead.stop_session(session_id)
    Application.put_env(:mead, :storage, directory: directory, max_turns: 2)

    assert {:ok, _sizes} = Mead.compact_session(session_id)
    {:ok, stored} = Store.load(directory, session_id)
    assert Enum.map(stored, & &1.input) == ["question 7", "question 8"]
  end

  test "resume compacts the file and the history is identical", %{directory: directory} do
    session_id = session_with_turns(10)
    {:ok, history} = Mead.history(session_id)
    :ok = Mead.stop_session(session_id)
    before_size = File.stat!(file_of(directory, session_id)).size

    assert {:ok, ^session_id} = Mead.resume_session(session_id)

    assert File.stat!(file_of(directory, session_id)).size < before_size
    assert Mead.history(session_id) == {:ok, history}
    assert {:ok, _output} = Mead.submit_turn(session_id, "after resume")
    assert {:ok, loaded} = Store.load(directory, session_id)
    assert length(loaded) == 11
  end

  test "resume cuts a torn tail and then compacts", %{directory: directory} do
    session_id = session_with_turns(6)
    :ok = Mead.stop_session(session_id)
    path = file_of(directory, session_id)
    File.write!(path, <<0, 0, 0>>, [:append])

    capture_log(fn -> assert {:ok, ^session_id} = Mead.resume_session(session_id) end)

    assert {:ok, history} = Mead.history(session_id)
    assert length(history) == 6
    assert {:ok, ^history} = Store.load(directory, session_id)

    assert {:ok, %{bytes_before: size, bytes_after: size}} =
             Store.compact(directory, session_id, history)
  end

  test "resume still works when the compaction fails", %{directory: directory} do
    session_id = session_with_turns(6)
    {:ok, history} = Mead.history(session_id)
    :ok = Mead.stop_session(session_id)
    File.mkdir_p!(file_of(directory, session_id) <> ".tmp/inside")

    log = capture_log(fn -> assert {:ok, ^session_id} = Mead.resume_session(session_id) end)

    assert log =~ "could not compact"
    assert Mead.history(session_id) == {:ok, history}
  end

  test "compact_session/1 compacts a running session", %{directory: directory} do
    session_id = session_with_turns(10)
    before_size = File.stat!(file_of(directory, session_id)).size

    assert {:ok, %{bytes_before: ^before_size, bytes_after: after_size}} =
             Mead.compact_session(session_id)

    assert after_size < before_size
    assert Store.load(directory, session_id) == Mead.history(session_id)
  end

  test "compact_session/1 compacts a stopped session without starting it", %{
    directory: directory
  } do
    session_id = session_with_turns(10)
    {:ok, history} = Mead.history(session_id)
    :ok = Mead.stop_session(session_id)

    assert {:ok, %{bytes_after: after_size, bytes_before: before_size}} =
             Mead.compact_session(session_id)

    assert after_size < before_size
    assert Mead.history(session_id) == {:error, :not_found}
    assert Store.load(directory, session_id) == {:ok, history}
  end

  test "compact_session/1 is not found for unknown, invalid and unwritten sessions", %{
    directory: directory
  } do
    assert Mead.compact_session(Mead.UUID.generate()) == {:error, :not_found}
    assert Mead.compact_session("../x") == {:error, :not_found}
    assert Mead.compact_session("") == {:error, :not_found}

    {:ok, session_id} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(session_id) end)
    assert Mead.compact_session(session_id) == {:error, :not_found}
    assert File.ls!(directory) == []
  end

  test "compact_session/1 without storage is not found" do
    Application.delete_env(:mead, :storage)

    assert Mead.compact_session(Mead.UUID.generate()) == {:error, :not_found}
  end

  test "compact_session/1 leaves a damaged file untouched", %{directory: directory} do
    session_id = session_with_turns(4)
    :ok = Mead.stop_session(session_id)
    path = file_of(directory, session_id)
    damaged = File.read!(path)

    flipped =
      :binary.part(damaged, 0, 20) <>
        <<255>> <> :binary.part(damaged, 21, byte_size(damaged) - 21)

    File.write!(path, flipped)

    assert Mead.compact_session(session_id) == {:error, :corrupt_history}
    assert File.read!(path) == flipped
  end

  test "delete_session/1 also removes a temporary file left by a crashed compaction", %{
    directory: directory
  } do
    session_id = session_with_turns(2)
    :ok = Mead.stop_session(session_id)
    File.write!(file_of(directory, session_id) <> ".tmp", "leftover")

    assert Mead.delete_session(session_id) == :ok
    assert File.ls!(directory) == []
  end

  test "an explicit compaction without a file does not log a warning" do
    {:ok, session_id} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(session_id) end)

    log = capture_log(fn -> assert Mead.compact_session(session_id) == {:error, :not_found} end)

    refute log =~ "could not compact"
  end

  test "compact_session/1 waits for a slow compaction instead of reporting an unknown session" do
    session_id = session_with_turns(4)
    history = Mead.Session.whereis(session_id, :history)
    :ok = :sys.suspend(history)
    task = Task.async(fn -> Mead.compact_session(session_id) end)
    Process.sleep(5_300)
    :ok = :sys.resume(history)

    assert {:ok, %{bytes_before: before_size, bytes_after: after_size}} = Task.await(task)
    assert after_size < before_size
  end

  test "turns submitted while explicit compactions run are all kept, in memory and on disk", %{
    directory: directory
  } do
    {:ok, session_id} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(session_id) end)

    submitters =
      for index <- 1..30 do
        Task.async(fn -> Mead.submit_turn(session_id, "question #{index}") end)
      end

    compactors = for _round <- 1..10, do: Task.async(fn -> Mead.compact_session(session_id) end)

    accepted = submitters |> Task.await_many() |> Enum.count(&match?({:ok, _output}, &1))

    for result <- Task.await_many(compactors) do
      assert match?({:ok, _sizes}, result) or result == {:error, :not_found}
    end

    {:ok, memory} = Mead.history(session_id)
    assert accepted > 0
    assert length(memory) == accepted
    assert Store.load(directory, session_id) == {:ok, memory}
  end
end
