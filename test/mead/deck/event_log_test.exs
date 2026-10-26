defmodule Mead.Deck.EventLogTest do
  use ExUnit.Case, async: true

  alias Mead.Deck.EventLog

  @moduletag :tmp_dir

  @session_id "0b7a3c52-6f3e-4a55-9a52-6a9d8e7f1c01"

  defp event(sequence, text \\ "x") do
    %{
      "sequence" => sequence,
      "session_id" => @session_id,
      "type" => "text.delta",
      "occurred_at" => "2026-10-26T12:00:00Z",
      "payload" => %{"text" => text}
    }
  end

  defp append_all(log, sequences) do
    Enum.reduce(sequences, log, fn sequence, current ->
      {:ok, next} = EventLog.append(current, event(sequence))
      next
    end)
  end

  defp events_path(directory), do: Path.join(directory, @session_id <> ".events")

  test "an event appended without a sync is still on disk after a reopen", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    {:ok, log} = EventLog.append(log, event(1), sync: false)
    {:ok, _log} = EventLog.append(log, event(2))

    {:ok, reopened} = EventLog.open(directory, @session_id)
    assert Enum.map(EventLog.read_after(reopened, 0), & &1["sequence"]) == [1, 2]
  end

  test "an empty log has last_sequence 0", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    assert EventLog.last_sequence(log) == 0
    assert EventLog.read_after(log, 0) == []
  end

  test "appended events come back in order after a sequence", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    log = append_all(log, [1, 2, 3])

    assert EventLog.last_sequence(log) == 3
    assert Enum.map(EventLog.read_after(log, 0), & &1["sequence"]) == [1, 2, 3]
    assert Enum.map(EventLog.read_after(log, 1), & &1["sequence"]) == [2, 3]
    assert EventLog.read_after(log, 3) == []
    assert EventLog.read_after(log, 99) == []
  end

  test "a reopened log reads the same events", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    log = append_all(log, [1, 2])
    :ok = EventLog.close(log)

    {:ok, reopened} = EventLog.open(directory, @session_id)
    assert EventLog.last_sequence(reopened) == 2
    assert EventLog.read_after(reopened, 0) == [event(1), event(2)]
  end

  test "the file is private to its owner", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    _log = append_all(log, [1])

    assert File.stat!(events_path(directory)).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a torn tail is cut on open and later appends survive another reopen", %{
    tmp_dir: directory
  } do
    {:ok, log} = EventLog.open(directory, @session_id)
    _log = append_all(log, [1, 2])
    File.write!(events_path(directory), <<0, 0, 0>>, [:append])

    {:ok, reopened} = EventLog.open(directory, @session_id)
    assert EventLog.last_sequence(reopened) == 2
    {:ok, reopened} = EventLog.append(reopened, event(3))
    :ok = EventLog.close(reopened)

    {:ok, again} = EventLog.open(directory, @session_id)
    assert Enum.map(EventLog.read_after(again, 0), & &1["sequence"]) == [1, 2, 3]
  end

  test "damage in the middle is corrupt and the file is left untouched", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    _log = append_all(log, [1, 2, 3])

    original = File.read!(events_path(directory))

    flipped =
      :binary.part(original, 0, 2) <>
        <<Bitwise.bxor(:binary.at(original, 2), 0xFF)>> <>
        binary_part(original, 3, byte_size(original) - 3)

    File.write!(events_path(directory), flipped)

    assert {:error, :corrupt} = EventLog.open(directory, @session_id)
    assert File.read!(events_path(directory)) == flipped
  end

  test "memory mode keeps events for this value only", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(nil, @session_id)
    log = append_all(log, [1, 2])
    assert EventLog.last_sequence(log) == 2
    assert length(EventLog.read_after(log, 0)) == 2

    {:ok, fresh} = EventLog.open(nil, @session_id)
    assert EventLog.last_sequence(fresh) == 0
    assert File.ls!(directory) == []
  end

  test "delete removes the file and tolerates a missing one", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    _log = append_all(log, [1])
    assert File.exists?(events_path(directory))

    assert :ok = EventLog.delete(directory, @session_id)
    refute File.exists?(events_path(directory))
    assert :ok = EventLog.delete(directory, @session_id)
  end

  test "an invalid session id is refused and creates nothing", %{tmp_dir: directory} do
    for bad <- ["../x", "", "demo", "0b7a3c52-6f3e-4a55-9a52-6a9d8e7f1c0", nil, 5] do
      assert {:error, :invalid_session_id} = EventLog.open(directory, bad)
    end

    assert File.ls!(directory) == []
    assert :ok = EventLog.delete(directory, "../x")
  end

  test "a sequence that does not increase is refused and nothing is written", %{
    tmp_dir: directory
  } do
    {:ok, log} = EventLog.open(directory, @session_id)
    log = append_all(log, [1, 2])
    size = File.stat!(events_path(directory)).size

    assert {:error, :out_of_order} = EventLog.append(log, event(2))
    assert {:error, :out_of_order} = EventLog.append(log, event(1))
    assert {:error, :out_of_order} = EventLog.append(log, Map.delete(event(3), "sequence"))
    assert {:error, :out_of_order} = EventLog.append(log, Map.put(event(3), "sequence", nil))
    assert File.stat!(events_path(directory)).size == size
  end

  test "a write that fails leaves the log as it was", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(directory, @session_id)
    log = append_all(log, [1])
    File.chmod!(events_path(directory), 0o400)

    assert {:error, _reason} = EventLog.append(log, event(2))
    File.chmod!(events_path(directory), 0o600)
    assert EventLog.last_sequence(log) == 1
    {:ok, reopened} = EventLog.open(directory, @session_id)
    assert EventLog.last_sequence(reopened) == 1
  end

  test "a thousand events read back in order", %{tmp_dir: directory} do
    {:ok, log} = EventLog.open(nil, @session_id)
    log = append_all(log, 1..1_000)

    assert EventLog.last_sequence(log) == 1_000
    assert Enum.map(EventLog.read_after(log, 0), & &1["sequence"]) == Enum.to_list(1..1_000)

    assert Enum.map(EventLog.read_after(log, 995), & &1["sequence"]) == [
             996,
             997,
             998,
             999,
             1_000
           ]

    assert File.ls!(directory) == []
  end

  describe "compact/2" do
    defp policy_event(sequence) do
      %{event(sequence) | "type" => "policy.updated", "payload" => %{"level" => "allow_all"}}
    end

    test "a log within the limit is returned unchanged", %{tmp_dir: directory} do
      {:ok, log} = EventLog.open(directory, @session_id)
      log = append_all(log, [1, 2, 3])

      assert {:ok, ^log} = EventLog.compact(log, 3)
      assert EventLog.first_sequence(log) == 1
    end

    test "keeps the newest events and survives a reopen", %{tmp_dir: directory} do
      {:ok, log} = EventLog.open(directory, @session_id)
      log = append_all(log, 1..10)

      assert {:ok, compacted} = EventLog.compact(log, 4)
      assert Enum.map(EventLog.read_after(compacted, 0), & &1["sequence"]) == [7, 8, 9, 10]
      assert EventLog.last_sequence(compacted) == 10
      assert EventLog.count(compacted) == 4
      assert EventLog.first_sequence(compacted) == 7
      assert File.stat!(events_path(directory)).mode |> Bitwise.band(0o777) == 0o600

      {:ok, reopened} = EventLog.open(directory, @session_id)
      assert Enum.map(EventLog.read_after(reopened, 0), & &1["sequence"]) == [7, 8, 9, 10]
      assert EventLog.first_sequence(reopened) == 7
      assert {:ok, appended} = EventLog.append(reopened, event(11))
      assert EventLog.count(appended) == 5
    end

    test "keeps the latest policy event that would otherwise be dropped", %{tmp_dir: directory} do
      {:ok, log} = EventLog.open(directory, @session_id)
      {:ok, log} = EventLog.append(log, policy_event(1))
      log = append_all(log, 2..3)

      {:ok, log} =
        EventLog.append(log, %{policy_event(4) | "payload" => %{"level" => "ask_always"}})

      log = append_all(log, 5..10)

      assert {:ok, compacted} = EventLog.compact(log, 3)

      assert Enum.map(EventLog.read_after(compacted, 0), & &1["sequence"]) == [4, 8, 9, 10]
      assert EventLog.first_sequence(compacted) == 8
      assert Enum.at(EventLog.read_after(compacted, 0), 0)["payload"]["level"] == "ask_always"
    end

    test "keeps the remembered tool rules still in force and drops the ones taken back", %{
      tmp_dir: directory
    } do
      remembered = fn sequence, tool ->
        %{
          event(sequence)
          | "type" => "permission.resolved",
            "payload" => %{"remember" => tool}
        }
      end

      forgotten = fn sequence, tool ->
        %{event(sequence) | "type" => "permission.forgotten", "payload" => %{"tool" => tool}}
      end

      {:ok, log} = EventLog.open(directory, @session_id)

      log =
        Enum.reduce(
          [
            remembered.(1, "a__kept"),
            remembered.(2, "b__taken_back"),
            forgotten.(3, "b__taken_back"),
            event(4),
            event(5),
            event(6),
            event(7)
          ],
          log,
          fn entry, current ->
            {:ok, next} = EventLog.append(current, entry)
            next
          end
        )

      assert {:ok, compacted} = EventLog.compact(log, 2)
      kept = EventLog.read_after(compacted, 0)
      assert Enum.map(kept, & &1["sequence"]) == [1, 6, 7]
      assert hd(kept)["payload"]["remember"] == "a__kept"
      assert EventLog.first_sequence(compacted) == 6
    end

    test "leaves no temporary file and the old log when the rewrite fails", %{tmp_dir: directory} do
      {:ok, log} = EventLog.open(directory, @session_id)
      log = append_all(log, 1..5)
      File.mkdir_p!(events_path(directory) <> ".compact")

      assert {:error, _reason} = EventLog.compact(log, 2)
      assert EventLog.count(log) == 5
      {:ok, reopened} = EventLog.open(directory, @session_id)
      assert EventLog.last_sequence(reopened) == 5
      assert length(EventLog.read_after(reopened, 0)) == 5
    end

    test "memory mode compacts without touching the disk", %{tmp_dir: directory} do
      {:ok, log} = EventLog.open(nil, @session_id)
      log = append_all(log, 1..6)

      assert {:ok, compacted} = EventLog.compact(log, 2)
      assert Enum.map(EventLog.read_after(compacted, 0), & &1["sequence"]) == [5, 6]
      assert File.ls!(directory) == []
    end
  end
end
