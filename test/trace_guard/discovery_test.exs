defmodule TraceGuard.DiscoveryTest do
  # Finding reports whose response has no x-traceguard-id header.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import TraceGuard.TestHelpers

  @endpoint TraceGuard.TestApp.Endpoint

  setup do
    configure(incoming_header: "x-correlation-id", max_reports: 200)
    :ok
  end

  defp throw_request(correlation_id) do
    conn = put_req_header(build_conn(), "x-correlation-id", correlation_id)
    {500, headers, _} = assert_error_sent(500, fn -> get(conn, "/throw") end)
    # Plug does not wrap throws, so Phoenix renders without the trace header.
    assert trace_id(headers) == nil
  end

  test "concurrent header-less failures are distinguished by the caller's correlation ID" do
    ids = for i <- 1..20, do: "client-#{i}-#{System.unique_integer([:positive])}"

    ids
    |> Task.async_stream(&throw_request/1, max_concurrency: 20)
    |> Stream.run()

    trace_ids =
      for id <- ids do
        report = fetch_report_where!(incoming_id: id)

        assert report["request"]["incoming_id"] == %{
                 "header" => "x-correlation-id",
                 "value" => id
               }

        assert report["failure"]["kind"] == "throw"
        # Exactly one report per correlation ID: no cross-request matches.
        assert [%{"trace_id" => trace_id}] = TraceGuard.list_reports(incoming_id: id)
        assert trace_id == report["trace_id"]
        trace_id
      end

    assert length(Enum.uniq(trace_ids)) == 20
  end

  test "the request_id recorded in logs also finds the report" do
    throw_request("by-request-id")
    report = fetch_report_where!(incoming_id: "by-request-id")
    request_id = report["request"]["request_id"]

    assert is_binary(request_id)
    assert [%{"trace_id" => id}] = TraceGuard.list_reports(request_id: request_id)
    assert id == report["trace_id"]
  end

  test "filters combine by exact match and reject unknown keys" do
    throw_request("combo")
    fetch_report_where!(incoming_id: "combo")

    assert [_] = TraceGuard.list_reports(route: "/throw", kind: "throw", incoming_id: "combo")
    assert [] = TraceGuard.list_reports(route: "/throw", kind: "error", incoming_id: "combo")
    assert [] = TraceGuard.list_reports(incoming_id: "comb")
    assert_raise ArgumentError, fn -> TraceGuard.list_reports(path: "/throw") end
  end

  test "await_report/2 returns as soon as a report with a header is stored" do
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    id = trace_id(headers)
    assert {:ok, %{"trace_id" => ^id}} = TraceGuard.await_report(id, 1_000)
  end

  test "await_report/2 rejects malformed IDs and times out on unknown ones" do
    assert TraceGuard.await_report("../etc", 10) == {:error, :invalid_trace_id}
    unknown = TraceGuard.Context.generate_trace_id()
    assert TraceGuard.await_report(unknown, 20) == {:error, :timeout}
  end

  test "summaries carry no request data beyond what the redacted report holds" do
    conn =
      build_conn()
      |> put_req_header("x-correlation-id", "summary-check")
      |> put_req_header("authorization", "Bearer secret-token")

    assert_error_sent(500, fn -> get(conn, "/throw?password=hunter2") end)
    fetch_report_where!(incoming_id: "summary-check")

    [summary] = TraceGuard.list_reports(incoming_id: "summary-check")
    encoded = Jason.encode!(summary)
    refute encoded =~ "secret-token"
    refute encoded =~ "hunter2"

    assert Map.keys(summary) |> Enum.sort() ==
             ~w(captured_by exception generated_at incoming_id kind method outcome request_id route status trace_id)
  end
end
