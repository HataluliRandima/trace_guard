defmodule TraceGuard.Storage do
  @moduledoc """
  **Experimental in 0.1.0-rc.1** (the storage behaviour): the API may change before 1.0.

  Where finished reports go: a small behaviour plus the facade that the
  tracing engine and the public API call.

  The tracing engine only ever calls `put/1` and never knows which adapter is
  configured. The default adapter is `TraceGuard.ReportStore` (bounded,
  in-memory). Select another with:

      config :trace_guard, storage: MyAdapter
      config :trace_guard, storage: {MyAdapter, some: :option}

  ## Adapter contract

  * **Input is already redacted.** `c:put/2` receives the final, sanitized and
    redacted report (a JSON-safe, string-keyed map). Adapters must not need
    the raw data and never receive it.
  * **`c:put/2` must not block** for long and must never raise on overload.
    It returns:
      * `{:ok, :stored}` when the report was retained before returning;
      * `{:ok, :queued}` when it was *accepted* and will be retained
        asynchronously. The adapter must then call `stored/1` once it is
        retained, or `dropped/2` if it is lost;
      * `{:error, :overloaded}` when it was refused to protect memory;
      * `{:error, reason}` for any other failure.
    Returning `{:ok, _}` for a report that was refused is a contract
    violation: the facade counts and reports on what adapters return.
  * **Retention is bounded.** An adapter keeps at most a configured number of
    reports and evicts the oldest first (or documents its own policy). It
    must also bound any queue in front of its storage.
  * **Reads return, never exit, and honor `:timeout`.** `c:get/2` returns
    `{:ok, report}`, `:error` or `{:error, :unavailable}`; `c:list/1` returns
    summaries (see `summary/1`), newest first. When the facade passes
    `timeout: ms` in the options, reads must return within about that time.

  The facade adds what every adapter would otherwise have to repeat:
  exception safety (an adapter that raises or exits is reported as
  `{:error, {:adapter_failed, kind}}` and never reaches the request),
  counters, and telemetry events.

  ## Telemetry events

    * `[:trace_guard, :report, :stored]`: measurements `%{}`, metadata
      `%{trace_id: String.t(), summary: map()}`. Emitted when a report is
      retained (by the facade for `{:ok, :stored}`, by the adapter for
      `{:ok, :queued}`).
    * `[:trace_guard, :report, :dropped]`: metadata
      `%{trace_id: String.t(), reason: term()}`. Emitted when a report is
      not retained.

  TraceGuard's own handlers never subscribe to these events, and a request's
  trace context is removed before `put/1` runs, so storing a report can never
  produce further diagnostic events.
  """

  @type report :: %{required(String.t()) => term()}
  @type summary :: %{required(String.t()) => term()}
  @type put_result :: {:ok, :stored | :queued} | {:error, :overloaded | term()}

  @callback child_spec(keyword()) :: Supervisor.child_spec()
  @callback put(report(), keyword()) :: put_result()
  @callback get(String.t(), keyword()) :: {:ok, report()} | :error | {:error, :unavailable}
  @callback list(keyword()) :: [summary()] | {:error, :unavailable}
  @callback delete(String.t(), keyword()) :: :ok | {:error, :unavailable}
  @callback clear(keyword()) :: :ok | {:error, :unavailable}
  @callback stats(keyword()) :: map()

  @doc """
  Optional (Phase 6): summaries matching every `{field, value}` criterion
  exactly (fields are summary keys such as `"incoming_id"`), newest first.
  Lets an adapter filter in its database instead of returning every summary.
  The facade re-applies the criteria to whatever is returned, so an adapter
  can narrow results but never widen them.
  """
  @callback list_matching([{String.t(), term()}], keyword()) ::
              [summary()] | {:error, :unavailable}

  @optional_callbacks child_spec: 1, list_matching: 2

  @counters [:submitted, :accepted, :stored, :dropped_overloaded, :dropped_other, :lost]
  @counters_key {__MODULE__, :counters}

  ## Facade used by the engine

  @doc """
  Submits a finished report to the configured adapter.

  Never raises and never blocks beyond what the adapter's contract allows.
  Returns the adapter's outcome; any failure is also counted and emitted as a
  `[:trace_guard, :report, :dropped]` event.
  """
  @spec put(report()) :: put_result()
  def put(%{"trace_id" => trace_id} = report) do
    {adapter, opts} = adapter()
    count(:submitted)

    # Marked pending *before* the adapter can store it, so a fast store
    # cannot resolve the mark before it exists.
    TraceGuard.DropLog.pending(trace_id, adapter)

    result =
      try do
        adapter.put(report, opts)
      catch
        kind, _reason -> {:error, {:adapter_failed, kind}}
      end

    case result do
      {:ok, :stored} ->
        count(:accepted)
        stored(report)
        result

      {:ok, :queued} ->
        # Stays pending until the adapter calls stored/1 or dropped/2.
        count(:accepted)
        result

      {:error, reason} ->
        dropped(trace_id, reason)
        {:error, reason}

      other ->
        dropped(trace_id, {:invalid_adapter_result, other})
        {:error, {:invalid_adapter_result, other}}
    end
  end

  @doc """
  Fetches a report from the configured adapter. `opts` may contain
  `timeout: ms`, which adapters honor for the read.
  """
  @spec get(String.t(), keyword()) :: {:ok, report()} | :error | {:error, :unavailable}
  def get(trace_id, opts \\ []), do: safely(:get, [trace_id], {:error, :unavailable}, opts)

  @doc "Lists report summaries from the configured adapter, newest first."
  @spec list() :: [summary()] | {:error, :unavailable}
  def list, do: safely(:list, [], {:error, :unavailable})

  @doc """
  Summaries matching all `{field, value}` criteria exactly, newest first.
  Uses the adapter's `c:list_matching/2` when it has one, else `c:list/1`.
  """
  @spec list_matching([{String.t(), term()}]) :: [summary()] | {:error, :unavailable}
  def list_matching(criteria) do
    {adapter, _opts} = adapter()

    result =
      if criteria != [] and function_exported?(adapter, :list_matching, 2),
        do: safely(:list_matching, [criteria], {:error, :unavailable}),
        else: list()

    case result do
      summaries when is_list(summaries) ->
        Enum.filter(summaries, fn summary ->
          Enum.all?(criteria, fn {field, value} -> summary[field] == value end)
        end)

      error ->
        error
    end
  end

  @doc "Deletes one report."
  @spec delete(String.t()) :: :ok | {:error, :unavailable}
  def delete(trace_id), do: safely(:delete, [trace_id], {:error, :unavailable})

  @doc "Deletes all reports."
  @spec clear() :: :ok | {:error, :unavailable}
  def clear, do: safely(:clear, [], {:error, :unavailable})

  @doc """
  Submission counters (since the application started) merged with the
  adapter's own statistics.
  """
  @spec stats() :: map()
  def stats do
    adapter_stats = safely(:stats, [], %{})
    counters = counters()
    totals = Map.new(@counters, fn name -> {name, :counters.get(counters, index(name))} end)
    Map.merge(adapter_stats, totals)
  end

  defp safely(fun, args, fallback, call_opts \\ []) do
    {adapter, opts} = adapter()
    apply(adapter, fun, args ++ [Keyword.merge(opts, call_opts)])
  catch
    _kind, _reason -> fallback
  end

  @doc false
  def adapter do
    case TraceGuard.Config.get().storage do
      {module, opts} -> {module, opts}
      module -> {module, []}
    end
  end

  ## Helpers for adapters

  @doc """
  For adapters that returned `{:ok, :queued}`: call once the report is
  retained. Emits `[:trace_guard, :report, :stored]`.
  """
  @spec stored(report()) :: :ok
  def stored(%{"trace_id" => trace_id} = report) do
    count(:stored)
    TraceGuard.DropLog.resolve(trace_id)

    :telemetry.execute([:trace_guard, :report, :stored], %{}, %{
      trace_id: trace_id,
      summary: summary(report)
    })
  end

  @doc """
  For adapters that returned `{:ok, :queued}`: call if an accepted report is
  lost before being retained. Also used by the facade for refusals.
  Emits `[:trace_guard, :report, :dropped]`.
  """
  @spec dropped(String.t(), term()) :: :ok
  def dropped(trace_id, reason) do
    count(if reason == :overloaded, do: :dropped_overloaded, else: :dropped_other)
    TraceGuard.DropLog.record_drop(trace_id, reason)

    :telemetry.execute([:trace_guard, :report, :dropped], %{}, %{
      trace_id: trace_id,
      reason: reason
    })
  end

  @doc """
  For adapters that discover accepted reports were lost without knowing
  their trace IDs (for example, queued submissions that died with a crashed
  process). Only counted, as `:lost` in `stats/0`.
  """
  @spec lost(pos_integer()) :: :ok
  def lost(n) when is_integer(n) and n > 0, do: :counters.add(counters(), index(:lost), n)

  @doc """
  For a queueing adapter starting (or restarting): submissions still marked
  pending for `adapter` died with its previous incarnation. Each is recorded
  as a drop with reason `:lost` (so `TraceGuard.report_status/1` can say
  so) and counted in `:lost`. Returns the number.
  """
  @spec lost_pending(module()) :: non_neg_integer()
  def lost_pending(adapter) do
    n = TraceGuard.DropLog.lost_pending(adapter)
    if n > 0, do: lost(n)
    n
  end

  @doc """
  The summary of a report used by `list/0` and discovery filters. Built only
  from fields that are already in the (redacted) report.
  """
  @spec summary(report()) :: summary()
  def summary(report) do
    %{
      "trace_id" => report["trace_id"],
      "generated_at" => report["generated_at"],
      "outcome" => report["outcome"],
      "method" => get_in(report, ["request", "method"]),
      "route" => get_in(report, ["request", "route"]),
      "status" => get_in(report, ["response", "status"]),
      "kind" => get_in(report, ["failure", "kind"]),
      "exception" => get_in(report, ["failure", "exception"]),
      "captured_by" => get_in(report, ["failure", "captured_by"]),
      "request_id" => get_in(report, ["request", "request_id"]),
      "incoming_id" => get_in(report, ["request", "incoming_id", "value"])
    }
  end

  ## Counters (one :counters ref for the lifetime of the application)

  @doc false
  def init_counters do
    unless :persistent_term.get(@counters_key, nil) do
      :persistent_term.put(@counters_key, :counters.new(length(@counters), [:write_concurrency]))
    end

    :ok
  end

  defp counters do
    case :persistent_term.get(@counters_key, nil) do
      nil ->
        init_counters()
        :persistent_term.get(@counters_key)

      ref ->
        ref
    end
  end

  defp count(name), do: :counters.add(counters(), index(name), 1)

  for {name, i} <- Enum.with_index(@counters, 1) do
    defp index(unquote(name)), do: unquote(i)
  end
end
