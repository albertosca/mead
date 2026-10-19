defmodule Mead.Ledger do
  @moduledoc """
  In-memory ledger of what the router sends to providers.

  It listens to `[:mead, :router, :route]` and keeps, with no disk behind it:

    * a counter row per session, dropped by `forget/2` when the session is stopped;
    * a counter row per `{route, provider}`;
    * a ring of the last 100 turns.

  The process only owns the two public ETS tables, so they live as long as it does. The
  `:telemetry` handler writes to them in the process that emitted the event, which keeps the
  ledger off the critical path of every conversation and leaves no mailbox to grow under load.
  Because `:telemetry` detaches a handler that raises, the handler never raises: an event it cannot
  read is counted as `dropped`.

  A counter row is `{key, turns, failures, input_tokens, output_tokens, duration_ms}`.
  """

  use GenServer

  @default_event [:mead, :router, :route]
  @ring_size 100

  @doc """
  Starts the ledger.

  ## Options

    * `:name` - registered name; defaults to `Mead.Ledger`.
    * `:event` - the telemetry event to listen to; defaults to `[:mead, :router, :route]`. Tests
      give each ledger its own event so they do not see each other's turns.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @doc "Returns the totals of one session, or `{:error, :not_found}` if it was never seen."
  @spec session_totals(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def session_totals(session_id, ledger \\ __MODULE__) do
    %{counters: counters} = tables(ledger)

    case :ets.lookup(counters, {:session, session_id}) do
      [row] -> {:ok, totals_from(row)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns the totals over every route, plus `dropped`, the events that could not be read."
  @spec totals(GenServer.server()) :: map()
  def totals(ledger \\ __MODULE__) do
    %{counters: counters} = tables(ledger)

    summed =
      counters
      |> route_rows()
      |> Enum.map(&totals_from/1)
      |> Enum.reduce(empty_totals(), &add_totals/2)

    Map.put(summed, :dropped, dropped(counters))
  end

  @doc "Returns the totals per `{route, provider}`."
  @spec route_totals(GenServer.server()) :: %{{atom(), atom()} => map()}
  def route_totals(ledger \\ __MODULE__) do
    %{counters: counters} = tables(ledger)

    for {{:route, route, provider}, _turns, _failures, _input, _output, _duration} = row <-
          route_rows(counters),
        into: %{},
        do: {{route, provider}, totals_from(row)}
  end

  @doc "Returns up to `limit` of the most recent turns, newest first; at most 100 are kept."
  @spec recent(non_neg_integer(), GenServer.server()) :: [map()]
  def recent(limit, ledger \\ __MODULE__) when is_integer(limit) and limit >= 0 do
    %{ring: ring} = tables(ledger)

    ring
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_slot, sequence, _entry} -> sequence end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_slot, _sequence, entry} -> entry end)
  end

  @doc "Forgets the aggregate of a session; the route totals keep what the session added."
  @spec forget(String.t(), GenServer.server()) :: :ok
  def forget(session_id, ledger \\ __MODULE__) do
    %{counters: counters} = tables(ledger)
    :ets.delete(counters, {:session, session_id})
    :ok
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    event = Keyword.get(options, :event, @default_event)
    name = Keyword.get(options, :name, __MODULE__)
    handler_id = {__MODULE__, name}

    tables = %{
      counters: :ets.new(:mead_ledger_counters, [:set, :public, write_concurrency: true]),
      ring: :ets.new(:mead_ledger_ring, [:set, :public, write_concurrency: true])
    }

    # A ledger that was killed leaves its handler attached to dead tables, so attach replaces it.
    :telemetry.detach(handler_id)
    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, tables)

    {:ok, %{tables: tables, handler_id: handler_id}}
  end

  @impl true
  def handle_call(:tables, _from, state), do: {:reply, state.tables, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @doc false
  # The telemetry handler. It runs in the process that emitted the event and must never raise,
  # because `:telemetry` would detach it for good.
  def handle_event(_event, measurements, metadata, %{counters: counters, ring: ring}) do
    case normalize(measurements, metadata) do
      {:ok, entry} -> record(counters, ring, entry)
      :error -> :ets.update_counter(counters, :dropped, 1, {:dropped, 0})
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp normalize(
         %{input_tokens: input_tokens, output_tokens: output_tokens, duration: duration},
         %{route: route, route_source: route_source, provider: provider, status: status} =
           metadata
       )
       when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
              output_tokens >= 0 and is_integer(duration) and duration >= 0 and
              is_atom(route) and is_atom(route_source) and is_atom(provider) and
              status in [:ok, :error] do
    session_id = Map.get(metadata, :session_id)

    if is_nil(session_id) or is_binary(session_id) do
      {:ok,
       %{
         session_id: session_id,
         route: route,
         route_source: route_source,
         provider: provider,
         status: status,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         duration_ms: System.convert_time_unit(duration, :native, :millisecond)
       }}
    else
      :error
    end
  end

  defp normalize(_measurements, _metadata), do: :error

  defp record(counters, ring, entry) do
    failures = if entry.status == :ok, do: 0, else: 1

    operations = [
      {2, 1},
      {3, failures},
      {4, entry.input_tokens},
      {5, entry.output_tokens},
      {6, entry.duration_ms}
    ]

    if entry.session_id, do: bump(counters, {:session, entry.session_id}, operations)
    bump(counters, {:route, entry.route, entry.provider}, operations)

    write_ring(counters, ring, entry)
  end

  defp bump(counters, key, operations) do
    :ets.update_counter(counters, key, operations, {key, 0, 0, 0, 0, 0})
  end

  # The counter hands out a strictly increasing sequence, and the slot is its remainder, so a new
  # record replaces the oldest one with no cleanup pass.
  defp write_ring(counters, ring, entry) do
    sequence = :ets.update_counter(counters, :ring_index, 1, {:ring_index, 0})
    slot = rem(sequence - 1, @ring_size)
    :ets.insert(ring, {slot, sequence, Map.put(entry, :at, System.system_time(:millisecond))})
  end

  defp tables(ledger), do: GenServer.call(ledger, :tables)

  defp route_rows(counters) do
    :ets.match_object(counters, {{:route, :_, :_}, :_, :_, :_, :_, :_})
  end

  defp dropped(counters) do
    case :ets.lookup(counters, :dropped) do
      [{:dropped, count}] -> count
      [] -> 0
    end
  end

  defp totals_from({_key, turns, failures, input_tokens, output_tokens, duration_ms}) do
    %{
      turns: turns,
      failures: failures,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      duration_ms: duration_ms
    }
  end

  defp empty_totals do
    %{turns: 0, failures: 0, input_tokens: 0, output_tokens: 0, duration_ms: 0}
  end

  defp add_totals(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value -> left_value + right_value end)
  end
end
