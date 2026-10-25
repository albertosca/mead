defmodule Mead.Session.StoreCompactTest do
  use ExUnit.Case, async: true

  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    on_exit(fn -> File.chmod(directory, 0o700) end)
    %{directory: directory, session_id: Mead.UUID.generate()}
  end

  defp file_of(context), do: Path.join(context.directory, context.session_id <> ".log")

  # Writes the two records a closed turn leaves behind, the way History does.
  defp store_closed_turns(context, count) do
    for index <- 1..count do
      turn = Turn.start("question #{index}")
      :ok = Store.append(context.directory, context.session_id, {:append, turn})

      :ok =
        Store.append(
          context.directory,
          context.session_id,
          {:replace_last, Turn.finish(turn, :ok, "answer #{index}")}
        )
    end

    {:ok, turns} = Store.load(context.directory, context.session_id)
    turns
  end

  test "compacts to one record per turn and loads back identical", context do
    turns = store_closed_turns(context, 20)
    before_size = File.stat!(file_of(context)).size

    assert {:ok, %{bytes_before: ^before_size, bytes_after: bytes_after}} =
             Store.compact(context.directory, context.session_id, turns)

    assert bytes_after < before_size
    assert File.stat!(file_of(context)).size == bytes_after
    assert Store.load(context.directory, context.session_id) == {:ok, turns}
  end

  test "keeps in-progress turns and failed reasons exactly", context do
    store_closed_turns(context, 3)
    failed = Turn.finish(Turn.start("boom"), :failed, {:failed, %RuntimeError{message: "x"}})
    open = Turn.start("still running")

    for turn <- [failed, open] do
      :ok = Store.append(context.directory, context.session_id, {:append, turn})
    end

    {:ok, turns} = Store.load(context.directory, context.session_id)
    assert {:ok, _sizes} = Store.compact(context.directory, context.session_id, turns)

    assert {:ok, ^turns} = Store.load(context.directory, context.session_id)
    assert List.last(turns).status == :in_progress
  end

  test "a file already in canonical form is not rewritten", context do
    turns = store_closed_turns(context, 5)
    {:ok, first} = Store.compact(context.directory, context.session_id, turns)
    File.touch!(file_of(context), {{2026, 1, 1}, {0, 0, 0}})
    bytes = File.read!(file_of(context))

    assert {:ok, %{bytes_before: size, bytes_after: size}} =
             Store.compact(context.directory, context.session_id, turns)

    assert size == first.bytes_after
    assert File.read!(file_of(context)) == bytes

    assert File.stat!(file_of(context), time: :posix).mtime ==
             DateTime.to_unix(~U[2026-01-01 00:00:00Z])
  end

  test "the new file is private and no temporary file is left", context do
    turns = store_closed_turns(context, 5)
    {:ok, _sizes} = Store.compact(context.directory, context.session_id, turns)

    assert Bitwise.band(File.stat!(file_of(context)).mode, 0o777) == 0o600
    refute File.exists?(file_of(context) <> ".tmp")
  end

  test "a leftover temporary file from a crash is replaced, not appended to", context do
    turns = store_closed_turns(context, 5)
    File.write!(file_of(context) <> ".tmp", String.duplicate("garbage", 1_000))

    assert {:ok, _sizes} = Store.compact(context.directory, context.session_id, turns)

    assert Store.load(context.directory, context.session_id) == {:ok, turns}
    refute File.exists?(file_of(context) <> ".tmp")
  end

  test "a failed rewrite leaves the original untouched and no temporary file", context do
    turns = store_closed_turns(context, 5)
    original = File.read!(file_of(context))
    File.chmod!(context.directory, 0o500)

    assert {:error, {:persistence, _reason}} =
             Store.compact(context.directory, context.session_id, turns)

    File.chmod!(context.directory, 0o700)
    assert File.read!(file_of(context)) == original
    refute File.exists?(file_of(context) <> ".tmp")
  end

  test "an invalid id and a missing file are not found, and nothing is created", context do
    for session_id <- ["../x", "", String.upcase(context.session_id), context.session_id] do
      assert Store.compact(context.directory, session_id, [Turn.start("x")]) ==
               {:error, :not_found}
    end

    assert File.ls!(context.directory) == []
  end

  test "size/2 reports the bytes of the file", context do
    store_closed_turns(context, 2)

    assert {:ok, size} = Store.size(context.directory, context.session_id)
    assert size == File.stat!(file_of(context)).size
    assert Store.size(context.directory, Mead.UUID.generate()) == {:error, :not_found}
    assert Store.size(context.directory, "../x") == {:error, :not_found}
  end
end
