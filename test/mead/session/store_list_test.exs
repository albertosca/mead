defmodule Mead.Session.StoreListTest do
  use ExUnit.Case, async: true

  alias Mead.Session.Store

  @moduletag :tmp_dir

  defp store_session(directory) do
    session_id = Mead.UUID.generate()
    :ok = Store.append(directory, session_id, :interrupt)
    session_id
  end

  test "a missing directory has no sessions", %{tmp_dir: directory} do
    assert Store.list(Path.join(directory, "absent")) == {:ok, []}
  end

  test "an empty directory has no sessions", %{tmp_dir: directory} do
    assert Store.list(directory) == {:ok, []}
  end

  test "lists the stored sessions, newest first, with the modification time", %{
    tmp_dir: directory
  } do
    older = store_session(directory)
    newer = store_session(directory)
    File.touch!(Path.join(directory, older <> ".log"), {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(Path.join(directory, newer <> ".log"), {{2026, 2, 1}, {0, 0, 0}})

    assert {:ok, [first, second]} = Store.list(directory)
    assert first.session_id == newer
    assert second.session_id == older
    assert first.updated_at == ~U[2026-02-01 00:00:00Z]
    assert second.updated_at == ~U[2026-01-01 00:00:00Z]
  end

  test "ignores files and folders that are not session files", %{tmp_dir: directory} do
    session_id = store_session(directory)
    File.write!(Path.join(directory, "notes.txt"), "x")
    File.write!(Path.join(directory, String.upcase(session_id) <> ".log"), "x")
    File.write!(Path.join(directory, session_id <> ".log.bak"), "x")
    File.mkdir_p!(Path.join(directory, Mead.UUID.generate() <> ".log"))

    assert {:ok, [%{session_id: ^session_id}]} = Store.list(directory)
  end

  test "an unreadable directory is a persistence error", %{tmp_dir: directory} do
    path = Path.join(directory, "file")
    File.write!(path, "x")

    assert {:error, {:persistence, :enotdir}} = Store.list(path)
  end
end
