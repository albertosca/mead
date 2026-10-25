defmodule Mead.Ledger do
  @moduledoc """
  Ledger of what the router sends to providers, kept in memory and journaled to disk.

  It listens to `[:mead, :router, :route]` and keeps:

    * a counter row per session, dropped by `forget/2` when the session is deleted;
    * a counter row per `{route, provider}`;
    * a ring of the last 100 turns;
    * a count of the events it could not read.

  The process owns the two public ETS tables, so they live as long as it does. The `:telemetry` handler writes to them in the process that emitted the event, which keeps the ledger off the critical path of every conversation. Because `:telemetry` detaches a handler that raises, the handler never raises: an event it cannot read is counted as `dropped`.

  With a storage directory (`config :mead, :storage, directory: ...`, or the `:directory` option) the handler also casts every event to the ledger, which appends it to `ledger.journal` (`Mead.Ledger.JournalFile`) in batches of up to 100 events or 50 milliseconds, with one sync per batch, and again when it stops. A turn never waits for the disk. At boot the ledger replays the journal into the tables before it attaches the handler. A crash of the whole VM loses the events still waiting for the next batch. Without a directory the ledger is memory only and receives no casts.

  A counter row is `{key, turns, failures, input_tokens, output_tokens, duration_ms}`.
  """

  use GenServer

  require Logger

  alias Mead.Ledger.Journal
  alias Mead.Ledger.JournalFile
  alias Mead.Session.Store

  @default_event [:mead, :router, :route]
  @ring_size 100
  @flush_events 100
  @flush_after_ms 50
  @retry_after_ms 1_000
  @pending_limit 10_000

  @doc """
  Starts the ledger.

  ## Options

    * `:name` - registered name; defaults to `Mead.Ledger`.
    * `:event` - the telemetry event to listen to; defaults to `[:mead, :router, :route]`. Tests
      give each ledger its own event so they do not see each other's turns.
    * `:directory` - where the journal lives, or `nil` for a ledger that is memory only; defaults
      to `Mead.Session.Store.directory/0`.
    * `:journal_max_bytes` - the journal size from which it is rewritten as a checkpoint; defaults
      to `Mead.Session.Store.ledger_journal_max_bytes/0`.
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
    %{counters: counters} = configuration = tables(ledger)
    :ets.delete(counters, {:session, session_id})
    # Replay refuses a forget of anything but a string and would then set the whole journal aside.
    if is_binary(session_id), do: journal(configuration, {:forget, session_id})
    :ok
  end

  @doc """
  Writes the events that are pending now and returns `:ok`, or the error of the write.

  The ledger does this by itself within 50 milliseconds; this is for the caller that needs the journal to be current, such as a test.
  """
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(ledger \\ __MODULE__), do: GenServer.call(ledger, :flush, 30_000)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    event = Keyword.get(options, :event, @default_event)
    name = Keyword.get(options, :name, __MODULE__)
    directory = Keyword.get_lazy(options, :directory, &Store.directory/0)

    maximum_bytes =
      options
      |> Keyword.get_lazy(:journal_max_bytes, &Store.ledger_journal_max_bytes/0)
      |> validate_maximum_bytes!()

    handler_id = {__MODULE__, name}

    counters = :ets.new(:mead_ledger_counters, [:set, :public, write_concurrency: true])
    ring = :ets.new(:mead_ledger_ring, [:set, :public, write_concurrency: true])
    if directory, do: restore(counters, ring, JournalFile.load(directory))

    configuration = %{counters: counters, ring: ring, ledger: name, journal: directory != nil}

    # A ledger that was killed leaves its handler attached to dead tables, so attach replaces it.
    :telemetry.detach(handler_id)
    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, configuration)

    {:ok,
     %{
       tables: configuration,
       handler_id: handler_id,
       directory: directory,
       maximum_bytes: maximum_bytes,
       floor: 0,
       pending: [],
       pending_count: 0,
       timer: nil,
       failing: false
     }}
  end

  # The tables are loaded before the handler is attached, so no live event can interleave with
  # the replay. Sequences are renumbered from 1, which keeps the slot of each entry consistent
  # with the counter the next live turn continues from.
  defp restore(counters, ring, model) do
    Enum.each(Journal.rows(model), &:ets.insert(counters, &1))
    if Journal.dropped(model) > 0, do: :ets.insert(counters, {:dropped, Journal.dropped(model)})

    entries = Journal.ring_oldest_first(model)

    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, sequence} ->
      :ets.insert(ring, {rem(sequence - 1, @ring_size), sequence, entry})
    end)

    :ets.insert(counters, {:ring_index, length(entries)})
  end

  @impl true
  def handle_call(:tables, _from, state), do: {:reply, state.tables, state}

  def handle_call(:flush, _from, state) do
    {result, state} = flush_pending(state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:journal, _event}, %{directory: nil} = state), do: {:noreply, state}

  def handle_cast({:journal, event}, state) do
    state = enqueue(state, event)

    if state.pending_count >= @flush_events and not state.failing do
      {_result, state} = flush_pending(state)
      {:noreply, state}
    else
      {:noreply, ensure_timer(state)}
    end
  end

  @impl true
  def handle_info({:flush, reference}, %{timer: reference} = state) do
    {_result, state} = flush_pending(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    flush_pending(state)
    :ok
  end

  defp validate_maximum_bytes!(maximum_bytes)
       when is_integer(maximum_bytes) and maximum_bytes > 0,
       do: maximum_bytes

  defp validate_maximum_bytes!(maximum_bytes) do
    raise ArgumentError,
          "journal_max_bytes must be a positive integer, got: #{inspect(maximum_bytes)}"
  end

  # The newest event is first. Past the limit the oldest are dropped, so a dead disk cannot grow
  # the state of the ledger without bound.
  defp enqueue(state, event) do
    pending = [event | state.pending]
    count = state.pending_count + 1

    if count > @pending_limit do
      %{state | pending: Enum.take(pending, @pending_limit), pending_count: @pending_limit}
    else
      %{state | pending: pending, pending_count: count}
    end
  end

  defp ensure_timer(%{timer: nil} = state) do
    delay = if state.failing, do: @retry_after_ms, else: @flush_after_ms
    reference = make_ref()
    Process.send_after(self(), {:flush, reference}, delay)
    %{state | timer: reference}
  end

  defp ensure_timer(state), do: state

  defp flush_pending(%{pending: []} = state), do: {:ok, %{state | timer: nil}}

  defp flush_pending(state) do
    state = %{state | timer: nil}

    case JournalFile.append(state.directory, Enum.reverse(state.pending)) do
      :ok ->
        state = %{state | pending: [], pending_count: 0, failing: false}
        {:ok, checkpoint_if_due(state)}

      {:error, reason} ->
        unless state.failing do
          Logger.warning("could not write the ledger journal: #{inspect(reason)}")
        end

        {{:error, reason}, ensure_timer(%{state | failing: true})}
    end
  end

  # Rewrites the journal once it passes the limit and is half again as large as it was right after
  # the last rewrite. Without the second condition a checkpoint that is itself over the limit
  # would be rewritten on every flush.
  defp checkpoint_if_due(state) do
    size = JournalFile.size(state.directory)

    if size > state.maximum_bytes and size * 2 >= state.floor * 3 do
      checkpoint(state, size)
    else
      state
    end
  end

  # Built from the journal and not from the ETS tables: the tables may already hold an event whose
  # record the ledger has not written yet, and the checkpoint would then count it twice.
  defp checkpoint(state, size) do
    with {:ok, model, _valid_size, :clean} <- JournalFile.read(state.directory),
         :ok <- JournalFile.rewrite(state.directory, model) do
      %{state | floor: JournalFile.size(state.directory)}
    else
      problem ->
        Logger.warning("could not rewrite the ledger journal: #{inspect(problem)}")
        %{state | floor: size}
    end
  end

  @doc false
  # The telemetry handler. It runs in the process that emitted the event and must never raise,
  # because `:telemetry` would detach it for good.
  def handle_event(
        _event,
        measurements,
        metadata,
        %{counters: counters, ring: ring} = configuration
      ) do
    case normalize(measurements, metadata) do
      {:ok, entry} ->
        entry = Map.put(entry, :at, System.system_time(:millisecond))
        record(counters, ring, entry)
        journal(configuration, {:turn, entry})

      :error ->
        :ets.update_counter(counters, :dropped, 1, {:dropped, 0})
        journal(configuration, :dropped)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # A cast to a ledger that is not running is a no-op, so the handler stays safe. Without a
  # storage directory nothing is cast and the mailbox stays empty.
  defp journal(%{journal: true, ledger: ledger}, event),
    do: GenServer.cast(ledger, {:journal, event})

  defp journal(_configuration, _event), do: :ok

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
    operations = Journal.operations(entry)

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
    :ets.insert(ring, {slot, sequence, entry})
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
