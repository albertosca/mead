defmodule Mead.LedgerPersistenceTest do
  # Changes the global :storage setting and restarts the application's ledger, so it must not run
  # beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Ledger
  alias Mead.Ledger.JournalFile
  alias Mead.Test.FakeProvider

  @moduletag :tmp_dir

  # Terminating and restarting the child leaves the later root children running, unlike a kill,
  # which under rest_for_one restarts them all.
  defp restart_ledger do
    :ok = Supervisor.terminate_child(Mead.Supervisor, Mead.Ledger)
    {:ok, _pid} = Supervisor.restart_child(Mead.Supervisor, Mead.Ledger)
    :ok
  end

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    previous_router = Application.fetch_env(:mead, :router)

    Application.put_env(:mead, :storage, directory: directory)

    Application.put_env(:mead, :router,
      slots: [
        local: nil,
        cloud:
          {FakeProvider,
           test_pid: self(), result: {:ok, %{text: "cloud reply", usage: FakeProvider.usage()}}}
      ]
    )

    restart_ledger()

    on_exit(fn ->
      restore(:storage, previous_storage)
      restore(:router, previous_router)
      restart_ledger()
    end)

    {:ok, session_id} = Mead.start_session(handler: Mead.Router)
    %{directory: directory, session_id: session_id}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:mead, key, value)
  defp restore(key, :error), do: Application.delete_env(:mead, key)

  test "a resumed conversation keeps what it spent before it was stopped", context do
    %{session_id: session_id} = context
    assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")
    assert :ok = Mead.stop_session(session_id)
    assert {:ok, %{turns: 1, input_tokens: 5}} = Ledger.session_totals(session_id)

    restart_ledger()
    assert {:ok, %{turns: 1, input_tokens: 5}} = Ledger.session_totals(session_id)

    assert {:ok, ^session_id} = Mead.resume_session(session_id, handler: Mead.Router)
    assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "and this")

    assert {:ok, %{turns: 2, input_tokens: 10, output_tokens: 6}} =
             Ledger.session_totals(session_id)
  end

  test "deleting a conversation removes its counter for good, also after a restart", context do
    %{session_id: session_id} = context
    assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")
    assert {:ok, %{turns: 1}} = Ledger.session_totals(session_id)

    assert :ok = Mead.delete_session(session_id)
    assert Ledger.session_totals(session_id) == {:error, :not_found}

    restart_ledger()

    assert Ledger.session_totals(session_id) == {:error, :not_found}
    assert Ledger.route_totals()[{:cloud, FakeProvider}].turns >= 1
  end

  test "the journal is not mistaken for a conversation", context do
    %{directory: directory, session_id: session_id} = context
    assert {:ok, "cloud reply"} = Mead.submit_turn(session_id, "explain this")
    assert :ok = Ledger.flush()
    assert File.exists?(JournalFile.path(directory))

    assert {:ok, entries} = Mead.list_sessions()
    assert Enum.map(entries, & &1.session_id) == [session_id]
  end
end
