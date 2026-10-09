defmodule TraceGuard do
  @moduledoc """
  Diagnostic reports for failed Phoenix requests.

  When a request fails, TraceGuard reconstructs the timeline of telemetry
  events it could observe for that request (endpoint, router, Ecto queries,
  the exception), redacts sensitive values, and keeps a JSON-ready report.

  ## Setup

      # lib/my_app_web/endpoint.ex
      plug Plug.RequestId
      plug TraceGuard.Plug
      plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

      # config/config.exs
      config :trace_guard, ecto_telemetry_prefixes: [[:my_app, :repo]]

  ## Usage

      {:ok, report} = TraceGuard.get_report(trace_id)
      {:ok, json} = TraceGuard.export_json(trace_id, pretty: true)

  The trace ID of a failed request is returned in the `x-traceguard-id`
  response header and added to `Logger` metadata as `trace_guard_id`.

  ## Report structure (`traceguard.report/v1`)

      %{
        "schema" => "traceguard.report/v1",
        "trace_id" => "32 lowercase hex chars",
        "generated_at" => "ISO 8601 UTC timestamp",
        "outcome" => "exception" | "error_status",
        "request" => %{"method", "route", "path", "started_at", "request_id",
                       "incoming_id", "headers"},
        "response" => %{"status" => integer | nil},
        "duration_us" => integer,
        "events" => [%{"seq", "process", "name", "type", "offset_us",
                       "duration_us", "outcome", "metadata"}],
        "events_dropped" => integer,
        "failure" => nil | %{"kind", "exception", "message", "plug_status",
                             "stacktrace", "captured_by"},
        "tasks" => nil | %{"status", "processes", "events"},
        "redaction" => %{"applied", "placeholder", "sensitive_keys",
                         "redacted_values", "scrubbed_message_values"},
        "limitations" => [String.t()]
      }
  """

  alias TraceGuard.{Context, Exporter, Storage}

  @type report :: %{optional(String.t()) => term()}

  @doc """
  Returns the trace ID of the request being handled by the calling process,
  or nil outside a traced request.
  """
  @spec current_trace_id() :: String.t() | nil
  def current_trace_id do
    case Context.current() do
      %Context{trace_id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Binds `fun` to the calling process's trace, so that events emitted while
  it runs in another process (typically a `Task`) join that trace.

      Task.async(TraceGuard.wrap(fn -> Repo.all(Product) end))
      Task.async_stream(ids, TraceGuard.wrap(fn id -> Repo.get(Product, id) end))

  Accepts functions of arity 0 or 1. Returns `fun` unchanged when the
  calling process has no active trace, so it is safe to use anywhere.

  The wrapper preserves `fun`'s result and failures exactly (it re-raises
  with the original stacktrace). Only the trace ID and an internal collector
  reference are propagated; nothing else from the calling process is copied.
  See `TraceGuard.Propagation` for the full contract.
  """
  @spec wrap(fun) :: fun when fun: (-> any) | (any -> any)
  defdelegate wrap(fun), to: TraceGuard.Propagation

  @doc """
  Fetches the stored report for a failed request.

  Only well-formed trace IDs are looked up; anything else is rejected
  without touching the store. Returns `{:error, :unavailable}` (never exits)
  if the storage adapter cannot answer.
  """
  @spec get_report(String.t()) ::
          {:ok, report()} | {:error, :invalid_trace_id | :not_found | :unavailable}
  def get_report(trace_id) do
    if Context.valid_trace_id?(trace_id) do
      case Storage.get(trace_id) do
        {:ok, report} -> {:ok, report}
        :error -> {:error, :not_found}
        {:error, :unavailable} -> {:error, :unavailable}
      end
    else
      {:error, :invalid_trace_id}
    end
  end

  @doc """
  Waits until the report for `trace_id` is retained, then returns it.

  Reports are stored asynchronously after the response is sent. Instead of
  polling, this subscribes to TraceGuard's report events, then checks the
  store, so a report retained at any point is never missed:

    * `{:ok, report}` once it is retained;
    * `{:error, {:dropped, reason}}` if it is refused or lost *while waiting*
      (for example `:overloaded`);
    * `{:error, :timeout}` if neither happens within `timeout` ms. That
      includes a report that was dropped or evicted before the call.
  """
  @spec await_report(String.t(), timeout()) ::
          {:ok, report()}
          | {:error,
             :invalid_trace_id | :timeout | :not_found | :unavailable | {:dropped, term()}}
  def await_report(trace_id, timeout \\ 5_000) do
    if Context.valid_trace_id?(trace_id) do
      ref = make_ref()
      handler_id = {__MODULE__, :await_report, ref}

      :telemetry.attach_many(
        handler_id,
        [[:trace_guard, :report, :stored], [:trace_guard, :report, :dropped]],
        &__MODULE__.__forward_report_event__/4,
        {self(), ref, trace_id}
      )

      deadline = System.monotonic_time(:millisecond) + timeout
      remaining = fn -> max(deadline - System.monotonic_time(:millisecond), 0) end

      try do
        # The store read honors the same deadline, so a stalled store cannot
        # make this call take longer than `timeout`.
        case Storage.get(trace_id, timeout: timeout) do
          {:ok, report} ->
            {:ok, report}

          _not_yet ->
            receive do
              {^ref, :stored} -> fetch_after_stored(trace_id, remaining.())
              {^ref, {:dropped, reason}} -> {:error, {:dropped, reason}}
            after
              remaining.() -> {:error, :timeout}
            end
        end
      after
        :telemetry.detach(handler_id)
        flush_report_events(ref)
      end
    else
      {:error, :invalid_trace_id}
    end
  end

  defp fetch_after_stored(trace_id, timeout) do
    case Storage.get(trace_id, timeout: max(timeout, 1)) do
      {:ok, report} -> {:ok, report}
      :error -> {:error, :not_found}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc false
  def __forward_report_event__([:trace_guard, :report, event], _measurements, meta, config) do
    {pid, ref, trace_id} = config

    if meta.trace_id == trace_id do
      send(pid, {ref, if(event == :stored, do: :stored, else: {:dropped, meta.reason})})
    end
  end

  defp flush_report_events(ref) do
    receive do
      {^ref, _} -> flush_report_events(ref)
    after
      0 -> :ok
    end
  end

  @doc """
  Returns the report for `trace_id` encoded as JSON.

  Accepts the same options as `TraceGuard.Exporter.JSON.encode/2`.
  """
  @spec export_json(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :invalid_trace_id | :not_found | :unavailable | Exception.t()}
  def export_json(trace_id, opts \\ []) do
    with {:ok, report} <- get_report(trace_id) do
      Exporter.JSON.encode(report, opts)
    end
  end

  @list_filters %{
    trace_id: "trace_id",
    incoming_id: "incoming_id",
    request_id: "request_id",
    route: "route",
    method: "method",
    status: "status",
    outcome: "outcome",
    kind: "kind",
    exception: "exception"
  }

  @doc """
  Lists stored reports, newest first, as summaries.

  Every summary has `"trace_id"`, `"generated_at"`, `"outcome"`,
  `"method"`, `"route"`, `"status"`, `"kind"`, `"exception"`,
  `"captured_by"`, `"request_id"` and `"incoming_id"`.

  Filters narrow the list by exact match, for discovering reports whose
  response carried no `x-traceguard-id` header (exits, throws, failures
  outside the router):

      TraceGuard.list_reports(incoming_id: "checkout-7f3a")   # caller's correlation ID
      TraceGuard.list_reports(request_id: "F5zX...")         # Plug.RequestId, from logs
      TraceGuard.list_reports(route: "/api/orders/:id", kind: "exit")

  Supported filters: #{@list_filters |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &"`#{inspect(&1)}`")}.
  Unknown filters raise `ArgumentError`. Returns `[]` if the storage adapter
  is unavailable (see `report_stats/0`).
  """
  @spec list_reports(keyword()) :: [map()]
  def list_reports(filters \\ []) do
    criteria =
      Enum.map(filters, fn {key, value} ->
        case @list_filters do
          %{^key => field} -> {field, value}
          _ -> raise ArgumentError, "unknown list_reports/1 filter: #{inspect(key)}"
        end
      end)

    case Storage.list() do
      summaries when is_list(summaries) ->
        Enum.filter(summaries, fn summary ->
          Enum.all?(criteria, fn {field, value} -> summary[field] == value end)
        end)

      {:error, :unavailable} ->
        []
    end
  end

  @doc """
  Report submission and storage statistics.

  Counters since the application started: `:submitted`, `:accepted`,
  `:stored`, `:dropped_overloaded`, `:dropped_other` and `:lost` (accepted,
  then lost in a store restart). They are merged with the adapter's own
  figures, which for the default `TraceGuard.ReportStore` are `:retained`,
  `:max_reports`, `:pending`, `:max_pending_reports`, `:evicted` and
  `:available`.
  """
  @spec report_stats() :: map()
  defdelegate report_stats(), to: Storage, as: :stats

  @doc "Deletes one stored report."
  @spec delete_report(String.t()) :: :ok | {:error, :invalid_trace_id | :unavailable}
  def delete_report(trace_id) do
    if Context.valid_trace_id?(trace_id),
      do: Storage.delete(trace_id),
      else: {:error, :invalid_trace_id}
  end

  @doc "Deletes all stored reports."
  @spec clear_reports() :: :ok | {:error, :unavailable}
  def clear_reports, do: Storage.clear()
end
