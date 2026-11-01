defmodule Mead.Session.TurnStepsTest do
  use ExUnit.Case, async: true

  alias Mead.Session.Record
  alias Mead.Session.Store
  alias Mead.Session.Turn

  @session_id "0b7c6c1e-3c2a-4d7e-9f10-2a3b4c5d6e7f"

  setup do
    directory =
      Path.join(System.tmp_dir!(), "mead-turn-steps-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp write_events(directory, events) do
    for event <- events, do: :ok = Store.append(directory, @session_id, event)
  end

  test "a new turn has no steps, no continuations and the turn options it was given" do
    turn = Turn.start("hello", "key", %{route: :auto, tools: nil, interactive: false})

    assert turn.steps == []
    assert turn.resumes == 0
    assert turn.turn_options == %{route: :auto, tools: nil, interactive: false}
    assert Turn.start("hello").turn_options == %{}
  end

  test "closing a turn drops its steps" do
    turn = %{Turn.start("hello", "key") | steps: [:one]}

    assert Turn.finish(turn, :ok, "done").steps == []
    assert Turn.interrupt(turn).steps == []
  end

  test "step and resume events replay onto the turn in progress", %{directory: directory} do
    write_events(directory, [
      {:append, Turn.start("hello", "key")},
      {:step, :one},
      {:step, :two},
      {:resume, 1}
    ])

    assert {:ok, [turn]} = Store.load(directory, @session_id)
    assert turn.steps == [:one, :two]
    assert turn.resumes == 1
  end

  test "a step after the turn closed is a corrupt history", %{directory: directory} do
    started = Turn.start("hello", "key")

    write_events(directory, [
      {:append, started},
      {:replace_last, Turn.finish(started, :ok, "done")},
      {:step, :late}
    ])

    assert Store.load(directory, @session_id) == {:error, :corrupt_history}
  end

  test "a step or a resume with no turn is a corrupt history", %{directory: directory} do
    write_events(directory, [{:step, :orphan}])
    assert Store.load(directory, @session_id) == {:error, :corrupt_history}

    File.rm_rf!(directory)
    write_events(directory, [{:resume, 1}])
    assert Store.load(directory, @session_id) == {:error, :corrupt_history}
  end

  test "a turn written before steps existed loads with the defaults", %{directory: directory} do
    legacy =
      "hello"
      |> Turn.start("key")
      |> Map.from_struct()
      |> Map.drop([:steps, :resumes, :turn_options])
      |> Map.put(:__struct__, Turn)

    File.mkdir_p!(directory)
    path = Path.join(directory, @session_id <> ".log")
    File.write!(path, Record.encode({:append, legacy}))

    assert {:ok, [turn]} = Store.load(directory, @session_id)
    assert turn.steps == []
    assert turn.resumes == 0
    assert turn.turn_options == %{}
  end

  test "compaction keeps the steps of a turn in progress", %{directory: directory} do
    started = Turn.start("hello", "key", %{route: :auto, tools: nil, interactive: false})
    write_events(directory, [{:append, started}, {:step, :one}, {:step, :two}, {:resume, 2}])
    {:ok, turns} = Store.load(directory, @session_id)

    assert {:ok, _sizes} = Store.compact(directory, @session_id, turns)
    assert Store.load(directory, @session_id) == {:ok, turns}
  end
end
