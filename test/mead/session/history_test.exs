defmodule Mead.Session.HistoryTest do
  use ExUnit.Case, async: true

  alias Mead.Session.History
  alias Mead.Session.Turn

  setup do
    session_id = Mead.UUID.generate()
    start_supervised!({History, session_id: session_id})

    %{session_id: session_id}
  end

  test "all/1 returns turns in chronological order", %{session_id: session_id} do
    History.append(session_id, Turn.start("first"))
    History.append(session_id, Turn.start("second"))

    assert Enum.map(History.all(session_id), & &1.input) == ["first", "second"]
  end

  test "all/1 returns an empty list for a new session", %{session_id: session_id} do
    assert History.all(session_id) == []
  end

  test "update_last/2 changes only the newest turn", %{session_id: session_id} do
    History.append(session_id, Turn.start("first"))
    History.append(session_id, Turn.start("second"))

    History.update_last(session_id, &Turn.finish(&1, :ok, "done"))

    assert [%Turn{status: :in_progress}, %Turn{status: :ok, output: "done"}] =
             History.all(session_id)
  end

  test "mark_interrupted/1 turns in-progress turns into interrupted ones", %{
    session_id: session_id
  } do
    History.append(session_id, Turn.finish(Turn.start("finished"), :ok, "reply"))
    History.append(session_id, Turn.start("running"))

    History.mark_interrupted(session_id)

    assert [%Turn{status: :ok}, %Turn{status: :interrupted}] = History.all(session_id)
  end
end
