defmodule TraceGuard.EventCollector do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Appends diagnostic events to the calling process's `TraceGuard.Context`.

  Every event has the same internal shape:

      %{
        seq: 3,                       # order of observation within the process
        process: "request",           # "request", or "task-N" for propagated work
        name: "ecto.query",
        type: "db",
        at: -576460748160,            # System.monotonic_time(), see "Timestamps"
        duration: 1234 | nil,         # native time units, when the source reports one
        outcome: "ok" | "error" | nil,
        metadata: %{...}              # already filtered by the caller
      }

  ## Timestamps

  An event is timestamped when its telemetry handler runs, except the end
  of a span. Other handlers attached to the same event may run before
  TraceGuard's and do slow work of their own: error reporters such as
  ErrorTracker write to the database from their exception handler. Their
  queries are recorded first, but happened after the exception. So an event
  recorded with `span: {:stop, key}` is timestamped at the time of the
  matching `span: {:start, key}` event plus its own `:duration`, the time
  the span actually ended. Spans of the same key nest, as in a Phoenix
  router forwarding to another router.

  ## Bounding

  At most `:max_events` ordinary events are retained per trace. Further
  ordinary events are counted in `dropped` and discarded. *Lifecycle* events
  (request start/stop, exceptions, error rendering) are always retained; a
  request emits only a handful of them, so the total stays bounded.

  In a process running wrapped work (`role: :task`, see
  `TraceGuard.Propagation`), events are not stored locally but sent to the
  trace's task collector, within a budget of `:max_events` shared by all
  task processes of the trace. Task lifecycle events count against it.
  """

  alias TraceGuard.{Config, Context, Propagation}
  alias TraceGuard.Propagation.Token

  @type event_opts :: [
          duration: integer() | nil,
          outcome: String.t() | nil,
          lifecycle: boolean(),
          span: {:start | :stop, atom()}
        ]

  @doc """
  Records an event if the calling process has an active context.

  Returns `:ok` when recorded, `:dropped` when the event cap was reached and
  `:no_context` when the calling process is not handling a traced request.
  """
  @spec record(String.t(), String.t(), map(), event_opts()) :: :ok | :dropped | :no_context
  def record(name, type, metadata, opts \\ []) do
    case Context.current() do
      nil -> :no_context
      ctx -> record_in(ctx, name, type, metadata, opts)
    end
  end

  defp record_in(%Context{role: :task} = ctx, name, type, metadata, opts) do
    seq = ctx.seq + 1
    {at, ctx} = timestamp(ctx, opts)
    Context.put(%{ctx | seq: seq})

    event = %{
      seq: seq,
      name: name,
      type: type,
      at: at,
      duration: Keyword.get(opts, :duration),
      outcome: Keyword.get(opts, :outcome),
      metadata: metadata
    }

    Propagation.send_event(
      ctx.tasks,
      ctx.request[:kind] || "task",
      event,
      Config.get().max_events
    )
  end

  defp record_in(ctx, name, type, metadata, opts) do
    lifecycle? = Keyword.get(opts, :lifecycle, false)
    seq = ctx.seq + 1
    # Spans are tracked even for dropped events, so that a later lifecycle
    # event (an exception) still gets its time.
    {at, ctx} = timestamp(ctx, opts)

    if lifecycle? or ctx.retained < Config.get().max_events do
      event = %{
        seq: seq,
        process: "request",
        name: name,
        type: type,
        at: at,
        duration: Keyword.get(opts, :duration),
        outcome: Keyword.get(opts, :outcome),
        metadata: metadata
      }

      retained = if lifecycle?, do: ctx.retained, else: ctx.retained + 1
      Context.put(%{ctx | events: [event | ctx.events], seq: seq, retained: retained})
      :ok
    else
      Context.put(%{ctx | seq: seq, dropped: ctx.dropped + 1})
      :dropped
    end
  end

  defp timestamp(ctx, opts) do
    now = System.monotonic_time()

    case Keyword.get(opts, :span) do
      {:start, key} ->
        {now, %{ctx | spans: Map.update(ctx.spans, key, [now], &[now | &1])}}

      {:stop, key} ->
        case ctx.spans do
          %{^key => [started | open]} ->
            duration = Keyword.get(opts, :duration)
            at = if is_integer(duration), do: min(started + duration, now), else: now
            {at, %{ctx | spans: Map.put(ctx.spans, key, open)}}

          _no_open_span ->
            {now, ctx}
        end

      nil ->
        {now, ctx}
    end
  end

  @doc """
  Returns true if the calling process has an active trace whose buffer can
  still take an ordinary event. Lets handlers skip building metadata for
  events that would be dropped.
  """
  @spec accepting?() :: boolean()
  def accepting? do
    case Context.current() do
      %Context{role: :task, tasks: token} ->
        Propagation.accepting?(token, Config.get().max_events)

      %Context{retained: retained} ->
        retained < Config.get().max_events

      nil ->
        false
    end
  end

  @doc "Counts an ordinary event that was not recorded because the buffer is full."
  @spec record_dropped() :: :dropped | :no_context
  def record_dropped do
    case Context.current() do
      nil ->
        :no_context

      %Context{role: :task, tasks: token} ->
        Propagation.count_dropped(token)
        :dropped

      ctx ->
        Context.put(%{ctx | seq: ctx.seq + 1, dropped: ctx.dropped + 1})
        :dropped
    end
  end

  @doc """
  Records failure details on the active context.

  The first failure wins: a later, less specific signal (for example the
  endpoint's error rendering after the router already reported the
  exception) never overwrites it.
  """
  @spec put_failure(map()) :: :ok | :no_context
  def put_failure(failure) when is_map(failure) do
    case Context.current() do
      %Context{role: :request, failure: nil} = ctx -> Context.put(%{ctx | failure: failure})
      %Context{role: :request} -> :ok
      _no_request_context -> :no_context
    end
  end

  @doc """
  Completes the calling process's trace.

  The context is always removed. A report is built and stored only when the
  request failed: an exception was captured, or `status` is at least
  `:failure_status`. Successful requests leave nothing behind.

  If the request propagated its trace to tasks, the task collector is
  drained into the report (failed requests, waiting at most
  `:task_drain_timeout` ms) or discarded without waiting (successful ones).
  Only the process that owns the trace can complete it.

  Returns `{:reported, trace_id}` when the storage adapter accepted the
  report, `{:dropped, trace_id, reason}` when it did not (for example
  `:overloaded`), `:ok` (no failure) or `:no_context`. The trace context is
  removed *before* the report is stored, so storage can never add events to
  any trace.
  """
  @spec finish(integer() | nil) ::
          {:reported, String.t()} | {:dropped, String.t(), term()} | :ok | :no_context
  def finish(status) do
    config = Config.get()

    case Context.current() do
      %Context{role: :request} ->
        ctx = Context.take()

        if failed?(ctx, status, config) do
          report =
            ctx
            |> merge_tasks(config)
            |> TraceGuard.TraceBuilder.build(status, config)

          case TraceGuard.Storage.put(report) do
            {:ok, _accepted} -> {:reported, ctx.trace_id}
            {:error, reason} -> {:dropped, ctx.trace_id, reason}
          end
        else
          if match?(%Token{}, ctx.tasks), do: Propagation.discard(ctx.tasks)
          :ok
        end

      _no_request_context ->
        :no_context
    end
  end

  # Replaces the context's task token by a summary and merges task events,
  # keeping the trace-wide :max_events limit for ordinary events.
  defp merge_tasks(%Context{tasks: %Token{} = token} = ctx, config) do
    case Propagation.drain(token, config.task_drain_timeout) do
      {:ok, events, dropped} ->
        room = max(config.max_events - ctx.retained, 0)
        {kept, extra} = events |> Enum.sort_by(& &1.at) |> Enum.split(room)

        summary = %{
          status: "complete",
          processes: kept |> Enum.map(& &1.process) |> Enum.uniq() |> length(),
          events: length(kept)
        }

        %{
          ctx
          | events: kept ++ ctx.events,
            dropped: ctx.dropped + dropped + length(extra),
            tasks: summary
        }

      {status, dropped} ->
        summary = %{status: Atom.to_string(status), processes: nil, events: 0}
        %{ctx | dropped: ctx.dropped + dropped, tasks: summary}
    end
  end

  defp merge_tasks(%Context{tasks: :unavailable} = ctx, _config),
    do: %{ctx | tasks: %{status: "collector_limit_reached", processes: nil, events: 0}}

  defp merge_tasks(ctx, _config), do: ctx

  # An exception whose mapped status is below the threshold (for example a
  # 404 from Ecto.NoResultsError) is ordinary control flow, not a failure.
  defp failed?(ctx, status, config) do
    case status || (ctx.failure && ctx.failure.plug_status) do
      nil -> ctx.failure != nil
      effective_status -> effective_status >= config.failure_status
    end
  end

  @doc "Merges `fields` into the active context's request metadata."
  @spec put_request_fields(map()) :: :ok | :no_context
  def put_request_fields(fields) when is_map(fields) do
    case Context.current() do
      %Context{role: :request} = ctx ->
        Context.put(%{ctx | request: Map.merge(ctx.request, fields)})

      _no_request_context ->
        :no_context
    end
  end
end
