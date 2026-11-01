defmodule Mead.Session.HistoryStepsTest do
  use ExUnit.Case, async: true

  alias Mead.Session.History
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    session_id = Mead.UUID.generate()
    start_supervised!({History, session_id: session_id, directory: directory})
    :ok = History.append(session_id, Turn.start("hello", "key"))
    %{directory: directory, session_id: session_id}
  end

  defp stored(context) do
    {:ok, turns} = Store.load(context.directory, context.session_id)
    List.last(turns)
  end

  test "a step of the current attempt reaches the disk and memory", context do
    assert History.append_step(context.session_id, 0, :one) == :ok
    assert History.append_step(context.session_id, 0, :two) == :ok

    assert stored(context).steps == [:one, :two]
    assert History.newest(context.session_id).steps == [:one, :two]
  end

  test "a step of another attempt is stale and writes nothing", context do
    assert History.append_step(context.session_id, 1, :late) == {:error, :stale}

    assert stored(context).steps == []
    assert History.newest(context.session_id).steps == []
  end

  test "a step after the turn closed is stale", context do
    :ok = History.update_last(context.session_id, &Turn.finish(&1, :ok, "done"))

    assert History.append_step(context.session_id, 0, :late) == {:error, :stale}
    assert stored(context).status == :ok
  end

  test "a step that cannot be written is refused and memory is untouched", context do
    File.chmod!(Path.join(context.directory, context.session_id <> ".log"), 0o400)

    assert {:error, {:persistence, _reason}} = History.append_step(context.session_id, 0, :one)
    assert History.newest(context.session_id).steps == []
  end

  test "begin_resume counts continuations up to the maximum", context do
    assert {:ok, %Turn{resumes: 1}} = History.begin_resume(context.session_id, 3)
    assert {:ok, %Turn{resumes: 2}} = History.begin_resume(context.session_id, 3)
    assert {:ok, %Turn{resumes: 3}} = History.begin_resume(context.session_id, 3)
    assert History.begin_resume(context.session_id, 3) == {:error, :exhausted}

    assert stored(context).resumes == 3
  end

  test "a step of the new attempt applies once the continuation began", context do
    {:ok, _turn} = History.begin_resume(context.session_id, 3)

    assert History.append_step(context.session_id, 0, :late) == {:error, :stale}
    assert History.append_step(context.session_id, 1, :fresh) == :ok
    assert stored(context).steps == [:fresh]
  end

  test "begin_resume has nothing to do once the turn closed", context do
    :ok = History.update_last(context.session_id, &Turn.finish(&1, :ok, "done"))

    assert History.begin_resume(context.session_id, 3) == {:error, :nothing_to_resume}
  end

  test "newest is nil for an empty history" do
    session_id = Mead.UUID.generate()
    start_supervised!({History, session_id: session_id}, id: :empty)

    assert History.newest(session_id) == nil
  end
end
