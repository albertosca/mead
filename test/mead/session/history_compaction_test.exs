defmodule Mead.Session.HistoryCompactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Session.History
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    %{directory: directory, session_id: Mead.UUID.generate()}
  end

  defp start_history(context, extra) do
    options = [session_id: context.session_id, directory: context.directory] ++ extra
    start_supervised!({History, options})
  end

  defp file_of(context), do: Path.join(context.directory, context.session_id <> ".log")

  defp run_turn(context, index) do
    :ok = History.append(context.session_id, Turn.start("question #{index}"))
    :ok = History.update_last(context.session_id, &Turn.finish(&1, :ok, "answer #{index}"))
  end

  defp inode(context), do: File.stat!(file_of(context)).inode

  test "never compacts without a threshold", context do
    start_history(context, [])
    for index <- 1..30, do: run_turn(context, index)

    {:ok, size} = Store.size(context.directory, context.session_id)
    {:ok, turns} = Store.load(context.directory, context.session_id)

    assert {:ok, %{bytes_before: ^size, bytes_after: canonical}} =
             Store.compact(context.directory, context.session_id, turns)

    assert canonical < size
  end

  test "compacts from memory once the file passes the threshold and keeps appending", context do
    start_history(context, compact_after_bytes: 2_000)
    run_turn(context, 0)
    first_inode = inode(context)
    for index <- 1..40, do: run_turn(context, index)
    refute inode(context) == first_inode

    {:ok, turns} = Store.load(context.directory, context.session_id)
    assert turns == History.all(context.session_id)
    assert length(turns) == 41
    assert Enum.map(turns, & &1.input) == for(index <- 0..40, do: "question #{index}")

    run_turn(context, 41)
    assert {:ok, loaded} = Store.load(context.directory, context.session_id)
    assert loaded == History.all(context.session_id)
    assert length(loaded) == 42
  end

  test "rewrites rarely, not on every turn", context do
    start_history(context, compact_after_bytes: 1_000)

    inodes =
      for index <- 1..200 do
        run_turn(context, index)
        inode(context)
      end

    rewrites = inodes |> Enum.dedup() |> length()
    assert rewrites > 1
    assert rewrites < 40
  end

  test "turns appended from many processes are all present and in order", context do
    start_history(context, compact_after_bytes: 1_000)
    session_id = context.session_id

    1..60
    |> Enum.map(fn index ->
      Task.async(fn -> History.append(session_id, Turn.start("question #{index}")) end)
    end)
    |> Task.await_many(30_000)

    memory = History.all(context.session_id)
    assert length(memory) == 60
    assert Store.load(context.directory, context.session_id) == {:ok, memory}
  end

  test "a failing compaction does not fail the turn and is not retried on every turn", context do
    start_history(context, compact_after_bytes: 1)
    File.mkdir_p!(file_of(context) <> ".tmp/inside")

    log =
      capture_log(fn ->
        for index <- 1..20, do: run_turn(context, index)
      end)

    assert length(History.all(context.session_id)) == 20
    warnings = log |> String.split("could not compact") |> length() |> Kernel.-(1)
    assert warnings >= 1
    assert warnings < 10
    assert {:ok, turns} = Store.load(context.directory, context.session_id)
    assert length(turns) == 20
  end

  test "compact/1 rewrites on request and answers the sizes", context do
    start_history(context, [])
    for index <- 1..10, do: run_turn(context, index)
    {:ok, before_size} = Store.size(context.directory, context.session_id)

    assert {:ok, %{bytes_before: ^before_size, bytes_after: after_size}} =
             History.compact(context.session_id)

    assert after_size < before_size

    assert Store.load(context.directory, context.session_id) ==
             {:ok, History.all(context.session_id)}
  end

  describe "a file that was damaged before the history started" do
    setup context do
      history =
        start_supervised!({History, session_id: context.session_id, directory: context.directory},
          id: :first
        )

      for index <- 1..6, do: run_turn(context, index)
      stop_supervised!(:first)
      assert is_pid(history)

      path = file_of(context)
      bytes = File.read!(path)

      damaged =
        :binary.part(bytes, 0, 20) <> <<255>> <> :binary.part(bytes, 21, byte_size(bytes) - 21)

      File.write!(path, damaged)
      assert Store.load(context.directory, context.session_id) == {:error, :corrupt_history}
      %{damaged: damaged}
    end

    test "an explicit compaction refuses and leaves the file untouched", context do
      start_history(context, [])

      assert History.compact(context.session_id) == {:error, :corrupt_history}
      assert File.read!(file_of(context)) == context.damaged
    end

    test "the live trigger never rewrites it from an empty memory", context do
      start_history(context, compact_after_bytes: 1)
      for index <- 7..40, do: run_turn(context, index)

      assert Store.load(context.directory, context.session_id) == {:error, :corrupt_history}
      assert String.starts_with?(File.read!(file_of(context)), context.damaged)
    end
  end

  test "compact/1 on a history with no directory is not found", context do
    start_supervised!({History, session_id: context.session_id, directory: nil})

    assert History.compact(context.session_id) == {:error, :not_found}
  end
end
