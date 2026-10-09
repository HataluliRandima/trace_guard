defmodule TraceGuard.TestHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  @base [ecto_telemetry_prefixes: [[:test_app, :repo]]]

  @doc "Applies TraceGuard config for one test and restores the base config afterwards."
  def configure(opts \\ []) do
    TraceGuard.Config.put!(Keyword.merge(@base, opts))
    TraceGuard.Telemetry.attach()
    TraceGuard.clear_reports()

    on_exit(fn ->
      TraceGuard.Config.put!(@base)
      TraceGuard.Telemetry.attach()
    end)
  end

  def base_config, do: @base

  @doc """
  Fetches a report, allowing briefly for the asynchronous store write.

  ReportStore.put/1 is a cast. When the request ran in the test process the
  cast is always processed before a later call from that process; requests
  run in other processes (Tasks) get a short retry window.
  """
  def fetch_report!(trace_id, attempts \\ 50) do
    case TraceGuard.get_report(trace_id) do
      {:ok, report} ->
        report

      {:error, :not_found} when attempts > 0 ->
        Process.sleep(2)
        fetch_report!(trace_id, attempts - 1)

      other ->
        raise "no report for #{inspect(trace_id)}: #{inspect(other)}"
    end
  end

  def trace_id(conn_or_headers)

  def trace_id(%Plug.Conn{} = conn),
    do: conn |> Plug.Conn.get_resp_header("x-traceguard-id") |> List.first()

  def trace_id(headers) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if k == "x-traceguard-id", do: v end)
  end

  def event_names(report), do: Enum.map(report["events"], & &1["name"])
end
