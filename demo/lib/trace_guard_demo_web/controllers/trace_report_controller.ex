defmodule TraceGuardDemoWeb.TraceReportController do
  @moduledoc """
  Development-only access to TraceGuard reports. Routed only when
  `config :trace_guard_demo, :expose_trace_reports` is true (dev and test).
  Reports are already redacted when they are stored.
  """
  use TraceGuardDemoWeb, :controller

  def index(conn, _params), do: json(conn, %{data: TraceGuard.list_reports()})

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
