defmodule TraceGuard.ReportStoreTest do
  use ExUnit.Case, async: false

  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, Exporter, ReportStore}

  test "keeps at most :max_reports reports, evicting the oldest" do
    configure(max_reports: 3)
    ids = for _ <- 1..5, do: Context.generate_trace_id()
    for id <- ids, do: ReportStore.put(%{"trace_id" => id})

    assert Enum.map(ReportStore.list(), & &1["trace_id"]) ==
             ids |> Enum.take(-3) |> Enum.reverse()

    assert TraceGuard.get_report(hd(ids)) == {:error, :not_found}
  end

  test "get_report/1 validates the trace ID before lookup" do
    configure()
    assert TraceGuard.get_report("not-an-id") == {:error, :invalid_trace_id}
    assert TraceGuard.get_report(nil) == {:error, :invalid_trace_id}
    assert TraceGuard.export_json("../../etc") == {:error, :invalid_trace_id}
  end

  test "JSON export round-trips and can be written to a file" do
    configure()
    id = Context.generate_trace_id()
    report = %{"trace_id" => id, "events" => [%{"name" => "x", "offset_us" => 1}]}
    ReportStore.put(report)

    {:ok, json} = TraceGuard.export_json(id)
    assert Jason.decode!(json) == report

    {:ok, pretty} = TraceGuard.export_json(id, pretty: true)
    assert pretty =~ "\n"

    path = Path.join(System.tmp_dir!(), "traceguard_#{id}.json")
    on_exit(fn -> File.rm(path) end)
    assert :ok = Exporter.JSON.write(report, path)
    assert path |> File.read!() |> Jason.decode!() == report
  end
end
