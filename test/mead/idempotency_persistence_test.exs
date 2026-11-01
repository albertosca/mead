defmodule Mead.IdempotencyPersistenceTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous_storage do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    %{directory: directory}
  end

  test "Turn.start/2 records the key, and Turn.start/1 leaves it nil" do
    assert %Turn{client_turn_id: "key-1", status: :in_progress} = Turn.start("hello", "key-1")
    assert %Turn{client_turn_id: nil} = Turn.start("hello")
  end

  test "a turn written before the key existed loads with client_turn_id nil",
       %{directory: directory} do
    session_id = Mead.UUID.generate()

    # The shape a turn had before this slice: a %Turn{} map without the key.
    legacy = %{
      __struct__: Turn,
      input: "old question",
      output: "old answer",
      status: :ok,
      started_at: ~U[2026-10-30 12:00:00Z]
    }

    :ok = Store.append(directory, session_id, {:append, legacy})
    :ok = Store.append(directory, session_id, {:replace_last, legacy})

    assert {:ok, [turn]} = Store.load(directory, session_id)
    assert %Turn{client_turn_id: nil, input: "old question", status: :ok} = turn
    assert Map.fetch(turn, :client_turn_id) == {:ok, nil}
  end
end
