defmodule Mead.Deck.Tickets do
  @moduledoc """
  Single-use tickets that turn an authenticated `POST /deck/ticket` into one WebSocket upgrade.

  A ticket is 128 random bits, URL-safe, and lives in a public named ETS table owned by this
  process. `consume/2` is `:ets.take/2`, which is atomic, so two sockets presenting the same
  ticket at the same instant cannot both win. Expired tickets are refused on consume and swept
  periodically so abandoned ones do not accumulate. The ticket is a secret: it is never logged,
  and the server state is the table name only, so `:sys.get_state/1` shows none.
  """

  use GenServer

  @default_sweep_ms 5_000
  @maximum_ticket_bytes 64

  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec issue(atom(), String.t(), pos_integer()) :: String.t()
  def issue(server \\ __MODULE__, session_id, time_to_live_ms) do
    ticket = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    deadline = System.monotonic_time(:millisecond) + time_to_live_ms
    true = :ets.insert(server, {ticket, session_id, deadline})
    ticket
  end

  @spec consume(atom(), term()) :: {:ok, String.t()} | :error
  def consume(server \\ __MODULE__, ticket)

  def consume(server, ticket)
      when is_binary(ticket) and byte_size(ticket) <= @maximum_ticket_bytes do
    case :ets.take(server, ticket) do
      [{^ticket, session_id, deadline}] ->
        if System.monotonic_time(:millisecond) < deadline, do: {:ok, session_id}, else: :error

      [] ->
        :error
    end
  end

  def consume(_server, _ticket), do: :error

  @doc "How many tickets are held, expired ones included until the next sweep."
  @spec size(atom()) :: non_neg_integer()
  def size(server \\ __MODULE__), do: :ets.info(server, :size)

  @impl GenServer
  def init(options) do
    name = Keyword.get(options, :name, __MODULE__)
    sweep_ms = Keyword.get(options, :sweep_ms, @default_sweep_ms)
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep(sweep_ms)
    {:ok, %{table: name, sweep_ms: sweep_ms}}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table, sweep_ms: sweep_ms} = state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep(sweep_ms)
    {:noreply, state}
  end

  defp schedule_sweep(sweep_ms), do: Process.send_after(self(), :sweep, sweep_ms)
end
