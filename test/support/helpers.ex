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

  @doc "Waits (event-driven, no polling) for the report of `trace_id`."
  def fetch_report!(trace_id, timeout \\ 1_000) do
    case TraceGuard.await_report(trace_id, timeout) do
      {:ok, report} -> report
      other -> raise "no report for #{inspect(trace_id)}: #{inspect(other)}"
    end
  end

  @doc """
  Waits for the first stored report whose summary matches `filters`, for
  failures whose response carries no trace header. Subscribes before
  checking, so a report stored in between is not missed.
  """
  def fetch_report_where!(filters, timeout \\ 1_000) do
    handler = attach_report_events()

    try do
      case TraceGuard.list_reports(filters) do
        [%{"trace_id" => id} | _] -> fetch_report!(id)
        [] -> wait_for_match(filters, timeout)
      end
    after
      :telemetry.detach(handler)
    end
  end

  defp wait_for_match(filters, timeout) do
    receive do
      {:report_event, :stored, _id} ->
        case TraceGuard.list_reports(filters) do
          [%{"trace_id" => id} | _] -> fetch_report!(id)
          [] -> wait_for_match(filters, timeout)
        end
    after
      timeout -> raise "no report matching #{inspect(filters)}"
    end
  end

  @doc "Forwards [:trace_guard, :report, :stored | :dropped] events to the caller."
  def attach_report_events do
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:trace_guard, :report, :stored], [:trace_guard, :report, :dropped]],
      &__MODULE__.forward_report_event/4,
      self()
    )

    id
  end

  def forward_report_event([:trace_guard, :report, :stored], _, meta, pid),
    do: send(pid, {:report_event, :stored, meta.trace_id})

  def forward_report_event([:trace_guard, :report, :dropped], _, meta, pid),
    do: send(pid, {:report_event, {:dropped, meta.reason}, meta.trace_id})

  def trace_id(conn_or_headers)

  def trace_id(%Plug.Conn{} = conn),
    do: conn |> Plug.Conn.get_resp_header("x-traceguard-id") |> List.first()

  def trace_id(headers) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if k == "x-traceguard-id", do: v end)
  end

  def event_names(report), do: Enum.map(report["events"], & &1["name"])

  def query_sources(report) do
    for %{"name" => "ecto.query"} = e <- report["events"], do: e["metadata"]["source"]
  end

  def task_collector_count do
    DynamicSupervisor.count_children(TraceGuard.TaskCollectors).active
  end

  @doc "Blocks until `pid` has exited (no sleeps)."
  def await_exit(pid, timeout \\ 1_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> raise "process #{inspect(pid)} still alive after #{timeout} ms"
    end
  end
end
