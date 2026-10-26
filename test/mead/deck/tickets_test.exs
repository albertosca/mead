defmodule Mead.Deck.TicketsTest do
  use ExUnit.Case, async: true

  alias Mead.Deck.Tickets

  @session_id "0b7a3c52-6f3e-4a55-9a52-6a9d8e7f1c01"

  setup context do
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    sweep_ms = Map.get(context, :sweep_ms, 5_000)
    start_supervised!({Tickets, name: name, sweep_ms: sweep_ms})
    %{server: name}
  end

  test "a ticket consumes once", %{server: server} do
    ticket = Tickets.issue(server, @session_id, 5_000)

    assert {:ok, @session_id} = Tickets.consume(server, ticket)
    assert :error = Tickets.consume(server, ticket)
  end

  test "unknown, empty, non-binary and oversized tickets are refused", %{server: server} do
    for bad <- ["nope", "", nil, 5, :atom, %{}, String.duplicate("a", 10_000)] do
      assert :error = Tickets.consume(server, bad)
    end
  end

  test "an expired ticket is refused", %{server: server} do
    ticket = Tickets.issue(server, @session_id, 20)
    Process.sleep(60)

    assert :error = Tickets.consume(server, ticket)
  end

  test "two sockets racing for one ticket: exactly one wins", %{server: server} do
    for _round <- 1..200 do
      ticket = Tickets.issue(server, @session_id, 5_000)

      outcomes =
        1..4
        |> Enum.map(fn _index -> Task.async(fn -> Tickets.consume(server, ticket) end) end)
        |> Task.await_many()

      assert Enum.count(outcomes, &match?({:ok, @session_id}, &1)) == 1
      assert Enum.count(outcomes, &(&1 == :error)) == 3
    end
  end

  test "tickets are distinct, URL safe and long enough", %{server: server} do
    tickets = for _index <- 1..1_000, do: Tickets.issue(server, @session_id, 5_000)

    assert length(Enum.uniq(tickets)) == 1_000
    assert Enum.all?(tickets, &(byte_size(&1) >= 22 and &1 =~ ~r/\A[A-Za-z0-9_-]+\z/))
  end

  @tag sweep_ms: 20
  test "the sweep removes expired tickets and keeps live ones", %{server: server} do
    for _index <- 1..5, do: Tickets.issue(server, @session_id, 10)
    live = Tickets.issue(server, @session_id, 60_000)
    assert Tickets.size(server) == 6

    Process.sleep(120)

    assert Tickets.size(server) == 1
    assert {:ok, @session_id} = Tickets.consume(server, live)
  end

  test "inspecting the server state never shows a ticket", %{server: server} do
    ticket = Tickets.issue(server, @session_id, 5_000)

    refute inspect(:sys.get_state(server), limit: :infinity) =~ ticket
    refute inspect(:sys.get_status(server), limit: :infinity) =~ ticket
  end
end
