defmodule Mead.Ledger.JournalTest do
  use ExUnit.Case, async: true

  alias Mead.Ledger.Journal

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "session-a",
        route: :cloud,
        route_source: :classified,
        provider: Provider,
        status: :ok,
        input_tokens: 5,
        output_tokens: 3,
        duration_ms: 7,
        at: 1_000
      },
      overrides
    )
  end

  defp replay!(events) do
    assert {:ok, model} = Journal.replay(events)
    model
  end

  test "increments and operations describe one turn" do
    assert Journal.increments(entry()) == {1, 0, 5, 3, 7}
    assert Journal.increments(entry(%{status: :error})) == {1, 1, 5, 3, 7}
    assert Journal.operations(entry()) == [{2, 1}, {3, 0}, {4, 5}, {5, 3}, {6, 7}]
  end

  test "turns add up per session and per route" do
    model =
      replay!([
        {:turn, entry()},
        {:turn, entry(%{status: :error, input_tokens: 10})},
        {:turn, entry(%{session_id: "session-b", route: :local, provider: Other})}
      ])

    assert Enum.sort(Journal.rows(model)) ==
             Enum.sort([
               {{:session, "session-a"}, 2, 1, 15, 6, 14},
               {{:session, "session-b"}, 1, 0, 5, 3, 7},
               {{:route, :cloud, Provider}, 2, 1, 15, 6, 14},
               {{:route, :local, Other}, 1, 0, 5, 3, 7}
             ])
  end

  test "a turn without a session counts for its route only" do
    model = replay!([{:turn, entry(%{session_id: nil})}])

    assert Journal.rows(model) == [{{:route, :cloud, Provider}, 1, 0, 5, 3, 7}]
  end

  test "the ring keeps the newest 100 entries" do
    events = for index <- 1..150, do: {:turn, entry(%{input_tokens: index})}
    model = replay!(events)

    oldest_first = Journal.ring_oldest_first(model)
    assert length(oldest_first) == 100
    assert hd(oldest_first).input_tokens == 51
    assert List.last(oldest_first).input_tokens == 150
  end

  test "forget removes the session row and keeps the route rows" do
    model = replay!([{:turn, entry()}, {:forget, "session-a"}])

    assert Journal.rows(model) == [{{:route, :cloud, Provider}, 1, 0, 5, 3, 7}]
    assert length(Journal.ring_oldest_first(model)) == 1
  end

  test "dropped counts the events nobody could read" do
    assert Journal.dropped(replay!([:dropped, :dropped, {:turn, entry()}])) == 2
  end

  test "a checkpoint replays to the state it was taken from" do
    model =
      replay!([
        {:turn, entry()},
        {:turn, entry(%{session_id: "session-b", status: :error})},
        :dropped
      ])

    restored = replay!([Journal.checkpoint(model)])

    assert Enum.sort(Journal.rows(restored)) == Enum.sort(Journal.rows(model))
    assert Journal.ring_oldest_first(restored) == Journal.ring_oldest_first(model)
    assert Journal.dropped(restored) == 1
  end

  test "a checkpoint replaces what came before it and later events build on it" do
    other = replay!([{:turn, entry(%{session_id: "session-z"})}])

    model =
      replay!([
        {:turn, entry()},
        Journal.checkpoint(other),
        {:turn, entry(%{session_id: "session-z"})}
      ])

    assert {{:session, "session-z"}, 2, 0, 10, 6, 14} in Journal.rows(model)
    refute Enum.any?(Journal.rows(model), &match?({{:session, "session-a"}, _, _, _, _, _}, &1))
  end

  test "an event nobody wrote is corrupt" do
    assert Journal.replay([:surprise]) == {:error, :corrupt}
    assert Journal.replay([{:turn, %{session_id: "x"}}]) == {:error, :corrupt}
    assert Journal.replay([{:forget, 7}]) == {:error, :corrupt}
  end

  test "a checkpoint with rows nobody writes is corrupt and never raises" do
    assert Journal.replay([{:checkpoint, [:row], []}]) == {:error, :corrupt}
    assert Journal.replay([{:checkpoint, [{:key, 1, 0, 0, 0}], []}]) == {:error, :corrupt}
    assert Journal.replay([{:checkpoint, [{:key, 1, 0, 0, 0, :x}], []}]) == {:error, :corrupt}
    assert Journal.replay([{:checkpoint, [{:dropped, 0}], []}]) == {:error, :corrupt}
    assert Journal.replay([{:checkpoint, [], [:entry]}]) == {:error, :corrupt}
  end
end
