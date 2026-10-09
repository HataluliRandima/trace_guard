defmodule TraceGuard.EventCollector do
  @moduledoc """
  Appends diagnostic events to the calling process's `TraceGuard.Context`.

  Every event has the same internal shape:

      %{
        seq: 3,                       # order of observation within the trace
        name: "ecto.query",
        type: "db",
        at: -576460748160,            # System.monotonic_time() when observed
        duration: 1234 | nil,         # native time units, when the source reports one
        outcome: "ok" | "error" | nil,
        metadata: %{...}              # already filtered by the caller
      }

  ## Bounding

  At most `:max_events` ordinary events are retained per trace. Further
  ordinary events are counted in `dropped` and discarded. *Lifecycle* events
  (request start/stop, exceptions, error rendering) are always retained; a
  request emits only a handful of them, so the total stays bounded.
  """

  alias TraceGuard.{Config, Context}

  @type event_opts :: [
          duration: integer() | nil,
          outcome: String.t() | nil,
          lifecycle: boolean()
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

  defp record_in(ctx, name, type, metadata, opts) do
    lifecycle? = Keyword.get(opts, :lifecycle, false)
    seq = ctx.seq + 1

    if lifecycle? or ctx.retained < Config.get().max_events do
      event = %{
        seq: seq,
        name: name,
        type: type,
        at: System.monotonic_time(),
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

  @doc """
  Records failure details on the active context.

  The first failure wins: a later, less specific signal (for example the
  endpoint's error rendering after the router already reported the
  exception) never overwrites it.
  """
  @spec put_failure(map()) :: :ok | :no_context
  def put_failure(failure) when is_map(failure) do
    case Context.current() do
      nil -> :no_context
      %{failure: nil} = ctx -> Context.put(%{ctx | failure: failure})
      _ctx -> :ok
    end
  end

  @doc """
  Completes the calling process's trace.

  The context is always removed. A report is built and stored only when the
  request failed: an exception was captured, or `status` is at least
  `:failure_status`. Successful requests leave nothing behind.

  Returns `{:reported, trace_id}`, `:ok` (no failure) or `:no_context`.
  """
  @spec finish(integer() | nil) :: {:reported, String.t()} | :ok | :no_context
  def finish(status) do
    config = Config.get()

    case Context.take() do
      nil ->
        :no_context

      ctx ->
        if failed?(ctx, status, config) do
          ctx |> TraceGuard.TraceBuilder.build(status, config) |> TraceGuard.ReportStore.put()
          {:reported, ctx.trace_id}
        else
          :ok
        end
    end
  end

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
      nil -> :no_context
      ctx -> Context.put(%{ctx | request: Map.merge(ctx.request, fields)})
    end
  end
end
