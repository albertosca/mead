defmodule Mead.LedgerJournalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mead.TestHelpers

  alias Mead.Ledger
  alias Mead.Ledger.Journal
  alias Mead.Ledger.JournalFile

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    name = :"journal_ledger_#{System.unique_integer([:positive])}"
    %{name: name, event: [:mead_test, name], directory: directory}
  end

  defp start_ledger(context, extra \\ []) do
    options =
      Keyword.merge(
        [name: context.name, event: context.event, directory: context.directory],
        extra
      )

    start_supervised!({Ledger, options}, id: context.name)
  end

  defp stop_ledger(context), do: stop_supervised!(context.name)

  defp emit(context, overrides \\ %{}, measurement_overrides \\ %{}) do
    metadata =
      Map.merge(
        %{
          route: :cloud,
          route_source: :classified,
          provider: Mead.Test.FakeProvider,
          status: :ok,
          session_id: "session-a"
        },
        overrides
      )

    measurements =
      Map.merge(
        %{
          duration: System.convert_time_unit(7, :millisecond, :native),
          input_tokens: 5,
          output_tokens: 3
        },
        measurement_overrides
      )

    :telemetry.execute(context.event, measurements, metadata)
  end

  defp snapshot(context) do
    name = context.name

    %{
      totals: Ledger.totals(name),
      routes: Ledger.route_totals(name),
      recent: Ledger.recent(100, name),
      sessions: Map.new(["session-a", "session-b"], &{&1, Ledger.session_totals(&1, name)})
    }
  end

  defp journaled_turns(directory) do
    {:ok, model, _size, _tail} = JournalFile.read(directory)

    model
    |> Journal.rows()
    |> Enum.filter(&match?({{:route, _, _}, _, _, _, _, _}, &1))
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp record_some_turns(context) do
    emit(context)
    emit(context, %{status: :error, route: :local, provider: Mead.Test.OtherProvider})
    emit(context, %{session_id: "session-b"}, %{input_tokens: 11})
    emit(context, %{}, %{input_tokens: -1})
  end

  describe "a restart" do
    test "restores every number, and the ring in the same order", context do
      start_ledger(context)
      record_some_turns(context)
      before_restart = snapshot(context)
      assert before_restart.totals.dropped == 1
      assert before_restart.totals.turns == 3

      stop_ledger(context)
      start_ledger(context)

      assert snapshot(context) == before_restart
    end

    test "keeps counting on top of what it restored", context do
      start_ledger(context)
      emit(context)
      stop_ledger(context)

      start_ledger(context)
      emit(context)

      assert {:ok, %{turns: 2, input_tokens: 10}} =
               Ledger.session_totals("session-a", context.name)
    end

    test "a forgotten session stays forgotten and the route totals stay", context do
      start_ledger(context)
      emit(context)
      emit(context, %{session_id: "session-b"})
      assert :ok = Ledger.forget("session-a", context.name)
      stop_ledger(context)

      start_ledger(context)

      assert Ledger.session_totals("session-a", context.name) == {:error, :not_found}
      assert {:ok, %{turns: 1}} = Ledger.session_totals("session-b", context.name)
      assert Ledger.totals(context.name).turns == 2
    end

    test "drops a torn tail with a warning and the next restart still reads the file", context do
      start_ledger(context)
      emit(context)
      stop_ledger(context)
      File.write!(JournalFile.path(context.directory), <<0, 0, 0, 40, 1>>, [:append])

      log = capture_log(fn -> start_ledger(context) end)
      assert log =~ "dropped an incomplete last record of the ledger journal"
      assert {:ok, %{turns: 1}} = Ledger.session_totals("session-a", context.name)

      emit(context)
      stop_ledger(context)
      start_ledger(context)

      assert {:ok, %{turns: 2}} = Ledger.session_totals("session-a", context.name)
    end

    test "sets a damaged journal aside, starts empty and keeps persisting", context do
      start_ledger(context)
      emit(context)
      emit(context)
      stop_ledger(context)
      path = JournalFile.path(context.directory)
      <<head::binary-size(13), byte, tail::binary>> = File.read!(path)
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 255), tail::binary>>)

      log = capture_log(fn -> start_ledger(context) end)

      assert log =~ "moved to ledger.journal.corrupt"
      assert File.exists?(path <> ".corrupt")
      assert Ledger.totals(context.name).turns == 0

      emit(context)
      stop_ledger(context)
      start_ledger(context)

      assert {:ok, %{turns: 1}} = Ledger.session_totals("session-a", context.name)
    end

    test "sets a damaged journal aside even when an earlier .corrupt is a directory", context do
      start_ledger(context)
      emit(context)
      emit(context)
      stop_ledger(context)
      path = JournalFile.path(context.directory)
      File.mkdir_p!(Path.join(path <> ".corrupt", "inside"))
      <<head::binary-size(13), byte, tail::binary>> = File.read!(path)
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 255), tail::binary>>)

      capture_log(fn -> start_ledger(context) end)

      refute File.exists?(path)
      assert File.regular?(path <> ".corrupt")

      emit(context)
      stop_ledger(context)
      start_ledger(context)

      assert {:ok, %{turns: 1}} = Ledger.session_totals("session-a", context.name)
    end
  end

  describe "the write path" do
    test "a full batch is written without waiting for the timer", context do
      start_ledger(context)
      for _index <- 1..100, do: emit(context)

      wait_until(fn -> journaled_turns(context.directory) == 100 end)
    end

    test "a single event is written within the flush delay", context do
      start_ledger(context)
      emit(context)

      wait_until(fn -> journaled_turns(context.directory) == 1 end)
    end

    test "flush/1 writes what is pending now", context do
      start_ledger(context)
      emit(context)
      emit(context)
      :sys.get_state(context.name)

      assert Ledger.flush(context.name) == :ok
      assert journaled_turns(context.directory) == 2
    end

    test "the handler does not wait for the ledger", context do
      start_ledger(context)
      %{tables: %{counters: counters}} = :sys.get_state(context.name)
      :sys.suspend(context.name)

      assert Task.async(fn -> emit(context) end) |> Task.await(2_000) == :ok

      assert [{{:session, "session-a"}, 1, 0, 5, 3, 7}] =
               :ets.lookup(counters, {:session, "session-a"})

      :sys.resume(context.name)
      assert Ledger.flush(context.name) == :ok
      assert journaled_turns(context.directory) == 1
    end

    test "a write that fails is logged once, counted anyway, and retried until it works",
         context do
      File.mkdir_p!(JournalFile.path(context.directory))
      capture_log(fn -> start_ledger(context) end)

      log =
        capture_log(fn ->
          emit(context)
          assert {:error, :eisdir} = Ledger.flush(context.name)
          emit(context)
          assert {:error, :eisdir} = Ledger.flush(context.name)
        end)

      assert length(String.split(log, "could not write the ledger journal")) == 2
      assert {:ok, %{turns: 2}} = Ledger.session_totals("session-a", context.name)

      File.rm_rf!(JournalFile.path(context.directory))
      assert Ledger.flush(context.name) == :ok
      assert journaled_turns(context.directory) == 2
    end

    test "a forget with an id that is not a string never damages the journal", context do
      start_ledger(context)
      emit(context)
      Ledger.forget(nil, context.name)
      Ledger.forget(123, context.name)
      assert Ledger.flush(context.name) == :ok

      stop_ledger(context)
      start_ledger(context)

      assert {:ok, %{turns: 1}} = Ledger.session_totals("session-a", context.name)
      refute File.exists?(JournalFile.path(context.directory) <> ".corrupt")
    end

    test "a journal that cannot be written keeps at most 10 000 pending events", context do
      File.mkdir_p!(JournalFile.path(context.directory))
      pid = capture_log(fn -> start_ledger(context) end) && Process.whereis(context.name)
      :sys.suspend(pid)
      for _index <- 1..10_050, do: emit(context)
      :sys.resume(pid)
      capture_log(fn -> assert {:error, :eisdir} = Ledger.flush(context.name) end)

      assert length(:sys.get_state(pid).pending) == 10_000
      assert Ledger.totals(context.name).turns == 10_050

      File.rm_rf!(JournalFile.path(context.directory))
      assert Ledger.flush(context.name) == :ok
      assert journaled_turns(context.directory) == 10_000
    end

    test "a journal size limit that is not a positive integer is refused", context do
      for invalid <- [0, -1, 1.5, "1"] do
        assert {:error, _reason} =
                 start_supervised(
                   {Ledger,
                    name: context.name,
                    event: context.event,
                    directory: context.directory,
                    journal_max_bytes: invalid},
                   id: {:invalid, invalid}
                 )
      end
    end

    test "a journal that cannot be written warns when it drops pending events", context do
      File.mkdir_p!(JournalFile.path(context.directory))
      pid = capture_log(fn -> start_ledger(context) end) && Process.whereis(context.name)
      :sys.suspend(pid)
      for _index <- 1..10_050, do: emit(context)
      :sys.resume(pid)

      log = capture_log(fn -> assert {:error, :eisdir} = Ledger.flush(context.name) end)

      assert log =~ "dropped 50 pending events of the ledger journal"
    end

    test "a forget survives the cap, so a deleted session stays deleted", context do
      start_ledger(context)
      emit(context)
      assert Ledger.flush(context.name) == :ok
      stop_ledger(context)

      path = JournalFile.path(context.directory)
      File.rename!(path, path <> ".saved")
      File.mkdir_p!(path)
      pid = capture_log(fn -> start_ledger(context) end) && Process.whereis(context.name)
      :sys.suspend(pid)
      Ledger.forget("session-a", context.name)
      for _index <- 1..10_100, do: emit(context, %{session_id: "session-b"})
      :sys.resume(pid)

      capture_log(fn -> assert {:error, :eisdir} = Ledger.flush(context.name) end)
      assert {:forget, "session-a"} in :sys.get_state(pid).pending
      assert length(:sys.get_state(pid).pending) == 10_000

      File.rm_rf!(path)
      File.rename!(path <> ".saved", path)
      assert Ledger.flush(context.name) == :ok
      stop_ledger(context)
      start_ledger(context)

      assert Ledger.session_totals("session-a", context.name) == {:error, :not_found}
    end

    test "the accessors and forget do not wait for a ledger stuck on the disk", context do
      start_ledger(context)
      emit(context)
      :sys.suspend(context.name)

      reads =
        Task.async(fn ->
          {Ledger.totals(context.name).turns, Ledger.session_totals("session-a", context.name),
           Ledger.recent(5, context.name) |> length(),
           Ledger.route_totals(context.name)
           |> map_size(), Ledger.forget("session-a", context.name)}
        end)

      assert {1, {:ok, %{turns: 1}}, 1, 1, :ok} = Task.await(reads, 1_000)
      :sys.resume(context.name)
    end

    test "an accessor of a ledger that is not running exits", context do
      assert {:noproc, _call} =
               catch_exit(
                 Ledger.totals(:"ledger_that_never_ran_#{System.unique_integer([:positive])}")
               )

      start_ledger(context)
      stop_ledger(context)
      assert {:noproc, _call} = catch_exit(Ledger.totals(context.name))
    end

    test "events still pending when the ledger stops are written", context do
      start_ledger(context)
      emit(context)
      stop_ledger(context)

      assert journaled_turns(context.directory) == 1
    end
  end

  describe "without a directory" do
    test "nothing is cast, nothing is written", context do
      pid = start_ledger(context, directory: nil)
      emit(context)
      emit(context)

      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      assert :sys.get_state(pid).pending == []
      assert Ledger.flush(context.name) == :ok
      assert File.ls!(context.directory) == []
      assert Ledger.totals(context.name).turns == 2
    end
  end

  describe "the checkpoint" do
    defp checkpoint_records(directory) do
      {:ok, records, _size, _tail} =
        directory |> JournalFile.path() |> File.read!() |> Mead.Session.Record.scan()

      records
    end

    test "shrinks the file, changes no total, and a restart equals it", context do
      start_ledger(context, journal_max_bytes: 1_000_000_000)
      for index <- 1..60, do: emit(context, %{session_id: "session-#{rem(index, 2)}"})
      stop_ledger(context)
      size_before = JournalFile.size(context.directory)

      start_ledger(context, journal_max_bytes: 600)
      emit(context, %{session_id: "session-a"})
      assert Ledger.flush(context.name) == :ok

      assert JournalFile.size(context.directory) < size_before
      assert [{:checkpoint, _rows, _ring}] = checkpoint_records(context.directory)
      assert Ledger.totals(context.name).turns == 61
      live = snapshot(context)

      stop_ledger(context)
      start_ledger(context, journal_max_bytes: 600)

      assert snapshot(context) == live
    end

    test "an event cast but not yet written is not counted twice", context do
      pid = start_ledger(context, journal_max_bytes: 1)
      emit(context)
      assert Ledger.flush(context.name) == :ok

      emit(context)
      :sys.get_state(context.name)
      :sys.suspend(context.name)

      flushing = Task.async(fn -> Ledger.flush(context.name) end)
      # The batch timer may also have queued a message, so wait for the flush call itself.
      wait_until(fn ->
        {:messages, messages} = Process.info(pid, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _from, _request}, &1))
      end)

      # The tables take this turn at once, but its journal record queues behind the flush that is
      # about to rewrite the file.
      emit(context)
      :sys.resume(context.name)
      assert Task.await(flushing, 5_000) == :ok
      assert Ledger.flush(context.name) == :ok

      assert Ledger.totals(context.name).turns == 3

      stop_ledger(context)
      start_ledger(context, journal_max_bytes: 1)

      assert {:ok, %{turns: 3}} = Ledger.session_totals("session-a", context.name)
      assert Ledger.totals(context.name).turns == 3
    end

    test "does not rewrite on every flush when the checkpoint itself is over the limit",
         context do
      start_ledger(context, journal_max_bytes: 1)

      inodes =
        for _index <- 1..40 do
          emit(context)
          assert Ledger.flush(context.name) == :ok
          File.stat!(JournalFile.path(context.directory)).inode
        end

      rewrites = inodes |> Enum.dedup() |> length()
      assert rewrites > 1
      assert rewrites < 30
      assert Ledger.totals(context.name).turns == 40
    end

    test "a failed rewrite leaves the journal readable and counts on", context do
      start_ledger(context, journal_max_bytes: 1)
      File.mkdir_p!(Path.join(JournalFile.path(context.directory) <> ".tmp", "inside"))

      log =
        capture_log(fn ->
          emit(context)
          assert Ledger.flush(context.name) == :ok
        end)

      assert log =~ "could not rewrite the ledger journal"
      assert journaled_turns(context.directory) == 1
      assert Ledger.totals(context.name).turns == 1
    end
  end

  test "the published tables are erased only after the shutdown flush", context do
    start_ledger(context)
    ledger = Process.whereis(context.name)

    # A pattern on a module that is not loaded yet matches nothing, and right after a recompile
    # the journal file module may not have been called by anyone so far.
    {:module, JournalFile} = Code.ensure_loaded(JournalFile)
    1 = :erlang.trace_pattern({JournalFile, :append, 2}, true, [:local])
    1 = :erlang.trace_pattern({:persistent_term, :erase, 1}, true, [:global])
    :erlang.trace(ledger, true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({JournalFile, :append, 2}, false, [:local])
      :erlang.trace_pattern({:persistent_term, :erase, 1}, false, [:global])
    end)

    # Traced before the event, so a batch the 50 ms timer flushes on a slow machine is seen too:
    # either way the one append comes before the erase.
    emit(context)
    stop_ledger(context)

    wait_until(fn ->
      {:messages, messages} = Process.info(self(), :messages)
      Enum.any?(messages, &match?({:trace, ^ledger, :call, {:persistent_term, :erase, _}}, &1))
    end)

    {:messages, messages} = Process.info(self(), :messages)

    calls =
      for {:trace, ^ledger, :call, {module, function, _arguments}} <- messages,
          do: {module, function}

    assert calls == [{JournalFile, :append}, {:persistent_term, :erase}]
  end
end
