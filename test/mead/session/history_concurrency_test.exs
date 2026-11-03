defmodule Mead.Session.HistoryConcurrencyTest do
  # Sixty appends queue on one History, and each one syncs with F_FULLFSYNC, which flushes the
  # whole drive. Run alongside the async modules that also sync, each flush waits for theirs and
  # the last append in the queue can pass the 5 s call timeout, so this module runs on its own.
  use ExUnit.Case, async: false

  alias Mead.Session.History
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    %{directory: directory, session_id: Mead.UUID.generate()}
  end

  test "turns appended from many processes are all present and in order", context do
    start_supervised!(
      {History,
       session_id: context.session_id, directory: context.directory, compact_after_bytes: 1_000}
    )

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
end
