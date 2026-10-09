defmodule TraceGuardDemoWeb.DiagnosticsTest do
  # End-to-end: real Phoenix endpoint, real Ecto queries against SQLite.
  # Not async: TraceGuard's report store is global.
  use TraceGuardDemoWeb.ConnCase, async: false

  import TraceGuardDemo.Fixtures

  alias TraceGuardDemo.Repo
  alias TraceGuardDemo.Shop.{Order, Product}

  setup do
    TraceGuard.clear_reports()
    %{product: product!()}
  end

  defp post_checkout(conn) do
    conn =
      Enum.reduce(checkout_headers(), conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)

    post(conn, ~p"/api/checkout", checkout_body())
  end

  test "healthy requests produce no report", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
    assert [id] = get_resp_header(conn, "x-traceguard-id")
    assert TraceGuard.get_report(id) == {:error, :not_found}

    conn = get(build_conn(), ~p"/api/products")
    assert [%{"sku" => "TG-001"}] = json_response(conn, 200)["data"]
    assert TraceGuard.list_reports() == []
  end

  describe "POST /api/checkout (deliberate failure)" do
    setup %{conn: conn} do
      {500, headers, body} = assert_error_sent(500, fn -> post_checkout(conn) end)
      %{headers: headers, body: body, report: fetch_report!(trace_id(headers))}
    end

    test "the client gets Phoenix's generic error, unchanged by TraceGuard", %{body: body} do
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
      refute body =~ "GatewayError"
    end

    test "application semantics are preserved: the transaction rolled back" do
      assert Repo.get_by!(Product, sku: "TG-001").stock == 25
      assert Repo.aggregate(Order, :count) == 0
    end

    test "the report correlates the real Ecto queries with the exception", %{report: report} do
      assert report["outcome"] == "exception"
      assert report["request"]["route"] == "/api/checkout"
      assert report["request"]["method"] == "POST"
      assert report["response"]["status"] == 500

      names = Enum.map(report["events"], & &1["name"])

      assert names == [
               "request.start",
               "phoenix.endpoint.start",
               "phoenix.router_dispatch.start",
               "ecto.query",
               "ecto.query",
               "ecto.query",
               "ecto.query",
               "ecto.query",
               "phoenix.router_dispatch.exception",
               "phoenix.endpoint.stop",
               "request.stop"
             ]

      assert [
               "begin",
               "SELECT" <> _,
               "UPDATE \"products\"" <> _,
               "INSERT INTO \"orders\"" <> _,
               "rollback"
             ] = ecto_sql(report)

      queries = Enum.filter(report["events"], &(&1["name"] == "ecto.query"))
      assert Enum.all?(queries, &(&1["metadata"]["repo"] == "TraceGuardDemo.Repo"))
      assert Enum.all?(queries, &(&1["outcome"] == "ok"))
      assert Enum.at(queries, 1)["metadata"]["source"] == "products"
      assert Enum.at(queries, 1)["metadata"]["origin"] =~ "TraceGuardDemo.Shop"

      assert report["failure"]["exception"] == "TraceGuardDemo.Payments.GatewayError"
      assert report["failure"]["message"] =~ "HTTP 502"
      assert hd(report["failure"]["stacktrace"])["module"] == "TraceGuardDemo.Payments"
    end

    test "sensitive values are absent from the exported JSON", %{report: report, headers: headers} do
      {:ok, json} = TraceGuard.export_json(trace_id(headers))

      for secret <- secrets(), do: refute(json =~ secret, "#{secret} leaked")

      assert report["request"]["headers"]["authorization"] == "[REDACTED]"
      assert report["request"]["headers"]["x-api-key"] == "[REDACTED]"
      assert report["failure"]["message"] =~ "api_key=[REDACTED]"
      assert report["redaction"]["applied"]
    end

    test "the report can be retrieved over the dev-only endpoint", %{headers: headers} do
      id = trace_id(headers)
      conn = get(build_conn(), ~p"/dev/traces/#{id}")
      assert json_response(conn, 200)["trace_id"] == id

      assert [%{"trace_id" => ^id}] =
               json_response(get(build_conn(), ~p"/dev/traces"), 200)["data"]

      assert json_response(get(build_conn(), ~p"/dev/traces/nope"), 400)

      assert [%{"trace_id" => ^id}] =
               json_response(get(build_conn(), "/dev/traces?route=/api/checkout&status=500"), 200)[
                 "data"
               ]

      assert [] = json_response(get(build_conn(), "/dev/traces?route=/api/health"), 200)["data"]
      assert json_response(get(build_conn(), ~p"/dev/traces/#{String.duplicate("0", 32)}"), 404)
    end
  end

  describe "Task propagation (TraceGuard.wrap/1)" do
    test "a successful parallel catalog produces no report and the same data", %{conn: conn} do
      sequential = json_response(get(conn, ~p"/api/catalog"), 200)
      parallel = json_response(get(build_conn(), ~p"/api/catalog/parallel"), 200)
      assert parallel == sequential
      assert TraceGuard.list_reports() == []
    end

    @tag :capture_log
    test "a failing child task's queries and exception are in the request's report",
         %{conn: conn} do
      conn = put_req_header(conn, "x-correlation-id", "reconcile-test-1")

      {500, headers, body} =
        assert_error_sent(500, fn -> post(conn, ~p"/api/inventory/reconcile") end)

      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}

      # Task.await exits the request process; Phoenix renders exits with the
      # endpoint's original conn, so the trace header is absent (documented).
      assert trace_id(headers) == nil
      # The caller's correlation ID finds it (incoming_header in config.exs).
      report = fetch_report_for_route!("/api/inventory/reconcile")

      assert [%{"trace_id" => id}] = TraceGuard.list_reports(incoming_id: "reconcile-test-1")
      assert id == report["trace_id"]

      assert report["failure"]["kind"] == "exit"
      assert report["failure"]["exception"] == "TraceGuardDemo.Shop.WarehouseError"

      assert report["failure"]["message"] ==
               "Task.await/2 exited: process crashed: warehouse feed timed out " <>
                 "after 3 retries (feed_token=[REDACTED])"

      assert report["tasks"]["status"] == "complete"
      assert report["tasks"]["processes"] == 2

      task_queries =
        for %{"name" => "ecto.query", "process" => "task-" <> _} = e <- report["events"],
            do: e["metadata"]["source"]

      assert Enum.sort(task_queries) == ["products", "products"]

      assert %{"metadata" => %{"exception" => "TraceGuardDemo.Shop.WarehouseError"}} =
               Enum.find(report["events"], &(&1["name"] == "task.exception"))

      refute Jason.encode!(report) =~ "wf_demo_42"
    end
  end

  test "an error response without an exception is reported with its queries", %{conn: conn} do
    conn = post(conn, ~p"/api/inventory/sync")
    assert json_response(conn, 503)

    report = conn |> get_resp_header("x-traceguard-id") |> hd() |> fetch_report!()
    assert report["outcome"] == "error_status"
    assert report["failure"] == nil

    assert [%{"metadata" => %{"source" => "products", "num_rows" => 1}}] =
             Enum.filter(report["events"], &(&1["name"] == "ecto.query"))
  end

  test "concurrent failing requests each get only their own events" do
    results =
      1..10
      |> Task.async_stream(
        fn i ->
          conn = put_req_header(build_conn(), "user-agent", "client-#{i}")
          {500, headers, _} = assert_error_sent(500, fn -> post_checkout(conn) end)
          {i, trace_id(headers)}
        end,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 10

    for {i, id} <- results do
      report = fetch_report!(id)
      assert report["request"]["headers"]["user-agent"] == "client-#{i}"
      assert ["begin", _, _, _, "rollback"] = ecto_sql(report)
    end
  end
end
