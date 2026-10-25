defmodule Mead.Session.HistoryPersistenceTest do
  use ExUnit.Case, async: true

  alias Mead.Session.History
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    %{directory: directory, session_id: Mead.UUID.generate()}
  end

  defp start_history(context, extra \\ []) do
    options = [session_id: context.session_id, directory: context.directory] ++ extra
    start_supervised!({History, options})
  end

  defp file_of(context), do: Path.join(context.directory, context.session_id <> ".log")

  test "append/2 writes the turn before it is visible", context do
    start_history(context)
    turn = Turn.start("first")

    assert History.append(context.session_id, turn) == :ok
    assert Store.load(context.directory, context.session_id) == {:ok, [turn]}
    assert History.all(context.session_id) == [turn]
  end

  test "update_last/2 stores the closed turn", context do
    start_history(context)
    History.append(context.session_id, Turn.start("first"))

    assert History.update_last(context.session_id, &Turn.finish(&1, :ok, "done")) == :ok

    assert {:ok, [%Turn{status: :ok, output: "done"}]} =
             Store.load(context.directory, context.session_id)
  end

  test "mark_interrupted/1 stores :interrupt only when a turn was in progress", context do
    start_history(context)
    History.append(context.session_id, Turn.start("running"))

    assert History.mark_interrupted(context.session_id) == :ok

    assert {:ok, [%Turn{status: :interrupted}]} =
             Store.load(context.directory, context.session_id)

    written = File.read!(file_of(context))
    assert History.mark_interrupted(context.session_id) == :ok
    assert File.read!(file_of(context)) == written
  end

  test "mark_interrupted/1 writes nothing when every turn is finished", context do
    start_history(context)
    History.append(context.session_id, Turn.finish(Turn.start("done"), :ok, "reply"))
    written = File.read!(file_of(context))

    assert History.mark_interrupted(context.session_id) == :ok
    assert File.read!(file_of(context)) == written
  end

  test "resume: starts from the given turns and appends after them", context do
    earlier = Turn.finish(Turn.start("earlier"), :ok, "reply")
    start_history(context, resume: [earlier])
    later = Turn.start("later")

    assert History.all(context.session_id) == [earlier]
    assert History.append(context.session_id, later) == :ok
    assert History.all(context.session_id) == [earlier, later]
  end

  test "append/2 refuses a turn it cannot write and leaves memory untouched", context do
    blocker = Path.join(context.directory, "blocker")
    File.write!(blocker, "")
    start_history(%{context | directory: Path.join(blocker, "inside")})

    assert History.append(context.session_id, Turn.start("lost")) ==
             {:error, {:persistence, :enotdir}}

    assert History.all(context.session_id) == []
  end

  test "update_last/2 reports a failed write but still changes memory", context do
    start_history(context)
    History.append(context.session_id, Turn.start("first"))
    File.chmod!(file_of(context), 0o400)

    assert History.update_last(context.session_id, &Turn.finish(&1, :ok, "done")) ==
             {:error, {:persistence, :eacces}}

    assert [%Turn{status: :ok, output: "done"}] = History.all(context.session_id)
  end

  test "without a directory nothing is written", context do
    start_supervised!({History, session_id: context.session_id})

    assert History.append(context.session_id, Turn.start("first")) == :ok
    assert File.ls!(context.directory) == []
  end
end
