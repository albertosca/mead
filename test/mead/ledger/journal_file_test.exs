defmodule Mead.Ledger.JournalFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Ledger.Journal
  alias Mead.Ledger.JournalFile

  @moduletag :tmp_dir

  defp entry(index) do
    %{
      session_id: "session-a",
      route: :cloud,
      route_source: :classified,
      provider: Provider,
      status: :ok,
      input_tokens: index,
      output_tokens: 1,
      duration_ms: 1,
      at: index
    }
  end

  defp turns(directory) do
    {:ok, model, _size, _tail} = JournalFile.read(directory)
    model |> Journal.rows() |> Enum.find(&match?({{:session, _}, _, _, _, _, _}, &1)) |> elem(1)
  end

  test "an absent journal reads as an empty model and creates nothing", %{tmp_dir: directory} do
    assert {:ok, model, 0, :clean} = JournalFile.read(directory)
    assert Journal.rows(model) == []
    assert JournalFile.load(directory) == Journal.new()
    assert File.ls!(directory) == []
    assert JournalFile.size(directory) == 0
  end

  test "appended events read back, and the file is private", %{tmp_dir: directory} do
    assert JournalFile.append(directory, [{:turn, entry(1)}, {:turn, entry(2)}]) == :ok
    assert JournalFile.append(directory, [{:turn, entry(3)}]) == :ok

    assert turns(directory) == 3
    assert JournalFile.size(directory) == File.stat!(JournalFile.path(directory)).size
    assert Bitwise.band(File.stat!(JournalFile.path(directory)).mode, 0o777) == 0o600
  end

  test "append creates the directory", %{tmp_dir: directory} do
    nested = Path.join(directory, "a/b")

    assert JournalFile.append(nested, [{:turn, entry(1)}]) == :ok
    assert turns(nested) == 1
  end

  test "a torn tail is dropped with a warning and cut off the file", %{tmp_dir: directory} do
    :ok = JournalFile.append(directory, [{:turn, entry(1)}, {:turn, entry(2)}])
    valid_size = JournalFile.size(directory)
    File.write!(JournalFile.path(directory), <<0, 0, 0, 40, 1>>, [:append])

    log = capture_log(fn -> assert turns_after_load(directory) == 2 end)

    assert log =~ "dropped an incomplete last record of the ledger journal"
    assert JournalFile.size(directory) == valid_size

    :ok = JournalFile.append(directory, [{:turn, entry(3)}])
    assert turns(directory) == 3
  end

  defp turns_after_load(directory) do
    model = JournalFile.load(directory)
    model |> Journal.rows() |> Enum.find(&match?({{:session, _}, _, _, _, _, _}, &1)) |> elem(1)
  end

  test "a record damaged before the last one sets the file aside", %{tmp_dir: directory} do
    :ok = JournalFile.append(directory, [{:turn, entry(1)}, {:turn, entry(2)}])
    path = JournalFile.path(directory)
    original = File.read!(path)
    <<head::binary-size(13), byte, tail::binary>> = original
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 255), tail::binary>>)

    log = capture_log(fn -> assert JournalFile.load(directory) == Journal.new() end)

    assert log =~ "moved to ledger.journal.corrupt"
    refute File.exists?(path)
    assert File.exists?(path <> ".corrupt")
  end

  test "a journal that cannot be read starts empty with a warning", %{tmp_dir: directory} do
    File.mkdir_p!(JournalFile.path(directory))

    log = capture_log(fn -> assert JournalFile.load(directory) == Journal.new() end)

    assert log =~ "could not read the ledger journal"
  end

  test "a failed append reports the error and leaves the file as it was", %{tmp_dir: directory} do
    :ok = JournalFile.append(directory, [{:turn, entry(1)}])
    path = JournalFile.path(directory)
    File.rm!(path)
    File.mkdir_p!(path)

    assert {:error, :eisdir} = JournalFile.append(directory, [{:turn, entry(2)}])
  end
end
