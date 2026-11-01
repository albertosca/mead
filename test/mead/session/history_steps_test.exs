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

  # A continuation whose infrastructure (the pool, the turn supervisor, the registry or the OS
  # process) changed since the last attempt was cut by that restart, not by the turn: it spends
  # nothing of the crash budget.
  test "continuations after infrastructure restarts do not spend the crash budget", context do
    for {generation, count} <- Enum.with_index([:first, :second, :third, :fourth, :fifth], 1) do
      assert {:ok, %Turn{resumes: ^count, crash_resumes: 0, generation: ^generation}} =
               History.begin_resume(context.session_id, 3, generation: generation)
    end

    assert %Turn{resumes: 5, crash_resumes: 0, generation: :fifth} = stored(context)
  end

  test "continuations under the same infrastructure spend the crash budget", context do
    # The turn started under no recorded generation, so the first continuation is a change.
    assert {:ok, %Turn{crash_resumes: 0}} =
             History.begin_resume(context.session_id, 3, generation: :same)

    for crash <- 1..3 do
      assert {:ok, %Turn{crash_resumes: ^crash}} =
               History.begin_resume(context.session_id, 3, generation: :same)
    end

    assert History.begin_resume(context.session_id, 3, generation: :same) == {:error, :exhausted}
    assert %Turn{resumes: 4, crash_resumes: 3} = stored(context)
  end

  test "infrastructure continuations stop at the total maximum", context do
    for generation <- [:first, :second] do
      assert {:ok, _turn} =
               History.begin_resume(context.session_id, 3,
                 generation: generation,
                 total_maximum: 2
               )
    end

    assert History.begin_resume(context.session_id, 3, generation: :third, total_maximum: 2) ==
             {:error, :exhausted}
  end

  test "a resume recorded before generations existed still loads", context do
    path = Path.join(context.directory, context.session_id <> ".log")
    File.write!(path, Mead.Session.Record.encode({:resume, 2}), [:append])

    assert %Turn{resumes: 2, crash_resumes: 2, generation: nil} = stored(context)
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
