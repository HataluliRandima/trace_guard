defmodule TraceGuard.DropLog do
  @moduledoc """
  A bounded record of recent report drops, and of submissions that were
  accepted but are not yet stored.

  It is used by `TraceGuard.report_status/1` and `TraceGuard.await_report/2`
  to tell a report that was **dropped** apart from one that is **pending**
  or simply **not observed**.

  ## What is recorded

  * **Drops:** `{trace_id, reason}`, recorded when the storage facade or an
    adapter reports one (`TraceGuard.Storage.dropped/2`), including
    `reason: :lost` for submissions that were accepted but died with a
    crashed store. Nothing else about the request is stored. Reasons are
    normalized to atoms, small tuples of atoms, integers and short strings;
    anything else becomes `:other`.
  * **Pending:** trace IDs submitted to an adapter that queues reports,
    removed as soon as the report is stored or dropped.

  ## Bounds and expiry

  * At most `:max_drop_records` drop records (default 1000). The oldest is
    evicted first. Under concurrent writers the count can briefly fall a
    little below the limit, never above it for longer than one insert.
  * A drop record expires after `:drop_record_ttl` ms (default 600_000),
    measured with the monotonic clock. Expired records are treated as absent
    on lookup and removed by a periodic sweep.
  * At most `:max_drop_records` pending entries. Pending entries older than
    `:drop_record_ttl` are removed (not turned into drops: a missing outcome
    is never reported as a drop).

  **An expired or evicted record means "unknown", never "not dropped".** The
  absence of a record is not evidence of anything.

  ## Concurrency

  The tables are public ETS tables owned by this process. Writers (request
  processes, store processes) insert directly, so there is no mailbox in
  the write path. If this process restarts, its records are lost and lookups
  answer "unknown" for them.
  """

  use GenServer

  @drops :trace_guard_drops
  @index :trace_guard_drop_index
  @pending :trace_guard_pending
  @seq {__MODULE__, :seq}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Writers

  @doc "Records that `trace_id`'s report was dropped for `reason`."
  @spec record_drop(String.t(), term()) :: :ok
  def record_drop(trace_id, reason) do
    guarded(fn ->
      config = TraceGuard.Config.get()
      seq = :atomics.add_get(:persistent_term.get(@seq), 1, 1)
      now = System.monotonic_time(:millisecond)

      :ets.delete(@pending, trace_id)
      :ets.insert(@drops, {trace_id, normalize(reason), now, seq})
      :ets.insert(@index, {seq, trace_id})
      trim(config.max_drop_records)
    end)
  end

  @doc "Marks `trace_id` as submitted to `adapter` and awaiting an outcome."
  @spec pending(String.t(), module()) :: :ok
  def pending(trace_id, adapter) do
    guarded(fn ->
      if :ets.info(@pending, :size) < TraceGuard.Config.get().max_drop_records do
        :ets.insert(@pending, {trace_id, adapter, System.monotonic_time(:millisecond)})
      end
    end)
  end

  @doc "Clears the pending mark of `trace_id` (stored, or refused synchronously)."
  @spec resolve(String.t()) :: :ok
  def resolve(trace_id), do: guarded(fn -> :ets.delete(@pending, trace_id) end)

  @doc """
  For a restarted adapter: every submission still pending for `adapter` was
  lost with the previous incarnation. Records each as a `:lost` drop and
  returns how many there were.
  """
  @spec lost_pending(module()) :: non_neg_integer()
  def lost_pending(adapter) do
    ids =
      try do
        :ets.select(@pending, [{{:"$1", adapter, :_}, [], [:"$1"]}])
      rescue
        ArgumentError -> []
      end

    Enum.each(ids, &record_drop(&1, :lost))
    length(ids)
  end

  ## Readers

  @doc "`{:dropped, reason}` if a live drop record exists, else `:none`."
  @spec lookup(String.t()) :: {:dropped, term()} | :none
  def lookup(trace_id) do
    ttl = TraceGuard.Config.get().drop_record_ttl

    case safe_lookup(@drops, trace_id) do
      [{^trace_id, reason, at, _seq}] ->
        if System.monotonic_time(:millisecond) - at <= ttl, do: {:dropped, reason}, else: :none

      _ ->
        :none
    end
  end

  @doc "True while `trace_id` was submitted and has no outcome yet."
  @spec pending?(String.t()) :: boolean()
  def pending?(trace_id), do: safe_lookup(@pending, trace_id) != []

  @doc "Current table sizes."
  @spec sizes() :: %{drop_records: non_neg_integer(), pending: non_neg_integer()}
  def sizes do
    %{drop_records: size(@drops), pending: size(@pending)}
  end

  @doc false
  # Removes expired drop records and stale pending entries now. Also runs
  # periodically.
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  ## GenServer

  @impl true
  def init(_opts) do
    for {name, type} <- [{@drops, :set}, {@index, :ordered_set}, {@pending, :set}] do
      :ets.new(name, [
        type,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :persistent_term.put(@seq, :atomics.new(1, []))
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    do_sweep()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    interval = min(TraceGuard.Config.get().drop_record_ttl, 60_000)
    Process.send_after(self(), :sweep, max(interval, 1_000))
  end

  defp do_sweep do
    cutoff = System.monotonic_time(:millisecond) - TraceGuard.Config.get().drop_record_ttl

    for {id, seq} <-
          :ets.select(@drops, [
            {{:"$1", :_, :"$2", :"$3"}, [{:<, :"$2", cutoff}], [{{:"$1", :"$3"}}]}
          ]) do
      :ets.delete(@index, seq)
      :ets.match_delete(@drops, {id, :_, :_, seq})
    end

    :ets.select_delete(@pending, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  ## Helpers

  # Evicts the oldest records until at most `max` remain. ets:take/2 makes
  # each eviction happen exactly once even with concurrent writers; the
  # drop row is deleted only if it still belongs to the evicted sequence
  # number (the same trace may have been recorded again since).
  defp trim(max) do
    if :ets.info(@index, :size) > max do
      case :ets.first(@index) do
        :"$end_of_table" ->
          :ok

        seq ->
          case :ets.take(@index, seq) do
            [{^seq, id}] -> :ets.match_delete(@drops, {id, :_, :_, seq})
            [] -> :ok
          end

          trim(max)
      end
    end

    :ok
  end

  defp normalize(reason) when is_atom(reason) or is_integer(reason), do: reason
  defp normalize(reason) when is_binary(reason), do: String.slice(reason, 0, 100)

  defp normalize(reason) when is_tuple(reason) and tuple_size(reason) <= 3,
    do: reason |> Tuple.to_list() |> Enum.map(&normalize_part/1) |> List.to_tuple()

  defp normalize(_reason), do: :other

  defp normalize_part(part) when is_atom(part) or is_integer(part), do: part
  defp normalize_part(part) when is_binary(part), do: String.slice(part, 0, 100)
  defp normalize_part(_part), do: :other

  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  defp size(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  defp guarded(fun) do
    fun.()
    :ok
  rescue
    # Tables missing (DropLog restarting): the record is skipped; lookups
    # then answer "unknown" for that trace, which is the documented
    # meaning of a missing record.
    ArgumentError -> :ok
  end
end
