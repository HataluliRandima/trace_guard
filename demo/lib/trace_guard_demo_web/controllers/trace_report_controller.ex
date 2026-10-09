defmodule TraceGuardDemoWeb.TraceReportController do
  @moduledoc """
  Development-only access to TraceGuard reports. Routed only when
  `config :trace_guard_demo, :expose_trace_reports` is true (dev and test).
  Reports are already redacted when they are stored.
  """
  use TraceGuardDemoWeb, :controller

  # Query parameters map to TraceGuard.list_reports/1 filters, e.g.
  # GET /dev/traces?incoming_id=checkout-42 for failures without a header.
  @filters %{
    "incoming_id" => :incoming_id,
    "request_id" => :request_id,
    "route" => :route,
    "method" => :method,
    "outcome" => :outcome,
    "kind" => :kind,
    "exception" => :exception,
    "status" => :status
  }

  def index(conn, params) do
    filters =
      for {param, value} <- params, Map.has_key?(@filters, param) do
        {@filters[param], if(param == "status", do: String.to_integer(value), else: value)}
      end

    json(conn, %{data: TraceGuard.list_reports(filters)})
  end

  def show(conn, %{"trace_id" => trace_id}) do
    case TraceGuard.get_report(trace_id) do
      {:ok, report} ->
        json(conn, report)

      {:error, :invalid_trace_id} ->
        conn |> put_status(:bad_request) |> json(%{errors: %{detail: "invalid trace id"}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "report not found"}})
    end
  end
end
