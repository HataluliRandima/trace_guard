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
        "events" => [%{"seq", "name", "type", "offset_us", "duration_us",
                       "outcome", "metadata"}],
        "events_dropped" => integer,
        "failure" => nil | %{"kind", "exception", "message", "plug_status",
                             "stacktrace", "captured_by"},
        "redaction" => %{"applied", "placeholder", "sensitive_keys",
                         "redacted_values", "scrubbed_message_values"},
        "limitations" => [String.t()]
      }
  """

  alias TraceGuard.{Context, Exporter, ReportStore}

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
  Fetches the stored report for a failed request.

  Only well-formed trace IDs are looked up; anything else is rejected
  without touching the store.
  """
  @spec get_report(String.t()) :: {:ok, report()} | {:error, :invalid_trace_id | :not_found}
  def get_report(trace_id) do
    cond do
      not Context.valid_trace_id?(trace_id) -> {:error, :invalid_trace_id}
      match?({:ok, _}, result = ReportStore.get(trace_id)) -> result
      true -> {:error, :not_found}
    end
  end

  @doc """
  Returns the report for `trace_id` encoded as JSON.

  Accepts the same options as `TraceGuard.Exporter.JSON.encode/2`.
  """
  @spec export_json(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_trace_id | :not_found | Exception.t()}
  def export_json(trace_id, opts \\ []) do
    with {:ok, report} <- get_report(trace_id) do
      Exporter.JSON.encode(report, opts)
    end
  end

  @doc """
  Lists stored reports, newest first, as short summaries.
  """
  @spec list_reports() :: [map()]
  def list_reports do
    Enum.map(ReportStore.list(), fn report ->
      %{
        "trace_id" => report["trace_id"],
        "generated_at" => report["generated_at"],
        "outcome" => report["outcome"],
        "method" => get_in(report, ["request", "method"]),
        "route" => get_in(report, ["request", "route"]),
        "status" => get_in(report, ["response", "status"]),
        "exception" => get_in(report, ["failure", "exception"])
      }
    end)
  end

  @doc "Deletes all stored reports."
  @spec clear_reports() :: :ok
  def clear_reports, do: ReportStore.clear()
end
