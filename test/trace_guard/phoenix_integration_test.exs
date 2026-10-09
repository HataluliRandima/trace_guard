defmodule TraceGuard.PhoenixIntegrationTest do
  # Exercises TraceGuard through a real Phoenix endpoint and router
  # (Phoenix.Endpoint.RenderErrors, Phoenix.Router dispatch telemetry,
  # Plug.Telemetry). Not async: changes global TraceGuard config.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import TraceGuard.TestHelpers

  @endpoint TraceGuard.TestApp.Endpoint

  setup do
    configure()
    :ok
  end

  describe "deliberate failure inside a controller" do
    setup do
      {status, headers, body} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
      %{status: status, headers: headers, body: body, report: fetch_report!(trace_id(headers))}
    end

    test "preserves Phoenix's normal error handling", %{body: body, headers: headers} do
      # assert_error_sent/2 only passes if Phoenix rendered the error *and*
      # re-raised the exception, i.e. TraceGuard swallowed nothing.
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
      refute body =~ "fake_gateway_key"
      refute body =~ "BoomError"
      assert {"x-traceguard-id", _} = List.keyfind(headers, "x-traceguard-id", 0)
    end

    test "captures the exception with the preceding events, in order", %{report: report} do
      assert report["outcome"] == "exception"
      assert report["response"]["status"] == 500
      assert report["request"]["method"] == "GET"
      assert report["request"]["route"] == "/crash"
      assert report["request"]["request_id"]

      assert event_names(report) == [
               "request.start",
               "phoenix.endpoint.start",
               "phoenix.router_dispatch.start",
               "ecto.query",
               "ecto.query",
               "phoenix.router_dispatch.exception",
               "phoenix.endpoint.stop",
               "request.stop"
             ]

      offsets = Enum.map(report["events"], & &1["offset_us"])
      assert offsets == Enum.sort(offsets)
      assert report["duration_us"] >= List.last(offsets)

      [ok_query, failed_query] = Enum.filter(report["events"], &(&1["name"] == "ecto.query"))
      assert ok_query["outcome"] == "ok"
      assert ok_query["metadata"]["num_rows"] == 1
      assert ok_query["duration_us"] == 175
      assert failed_query["outcome"] == "error"
      assert failed_query["metadata"]["error"] == "RuntimeError"

      failure = report["failure"]
      assert failure["captured_by"] == "phoenix.router_dispatch.exception"
      assert failure["exception"] == "TraceGuard.TestApp.BoomError"
      assert failure["kind"] == "error"
      assert failure["message"] == "payment gateway rejected api_key=[REDACTED] for user 42"

      assert %{"module" => "TraceGuard.TestApp.Controller", "function" => "crash/2"} =
               hd(failure["stacktrace"])
    end

    test "does not leak arbitrary telemetry metadata", %{report: report} do
      json = Jason.encode!(report)

      # Ecto params/cast_params, result rows, options, SQL text and conn data.
      for leaked <- [
            "super-secret-param",
            "alice@example.com",
            "do-not-leak",
            "SELECT",
            "fake_gateway_key_123"
          ] do
        refute json =~ leaked, "#{leaked} leaked into the report"
      end

      allowed = ~w(repo source query_time_us queue_time_us decode_time_us origin num_rows error)

      for %{"name" => "ecto.query", "metadata" => meta} <- report["events"] do
        assert Map.keys(meta) -- allowed == []
      end

      for %{"name" => "phoenix." <> _, "metadata" => meta} <- report["events"] do
        assert Map.keys(meta) -- ~w(route plug action pipe_through status kind exception) == []
      end
    end
  end

  test "successful requests produce no report and leave no context behind" do
    conn = get(build_conn(), "/ok")
    assert %{"ok" => true, "trace_id" => trace_id} = json_response(conn, 200)

    assert trace_id == trace_id(conn)
    assert TraceGuard.get_report(trace_id) == {:error, :not_found}
    assert TraceGuard.list_reports() == []
    assert TraceGuard.current_trace_id() == nil
  end

  test "an error status without an exception is reported" do
    conn = get(build_conn(), "/unavailable")
    assert conn.status == 503

    report = fetch_report!(trace_id(conn))
    assert report["outcome"] == "error_status"
    assert report["failure"] == nil
    assert "ecto.query" in event_names(report)
    assert Enum.any?(report["limitations"], &(&1 =~ "inferred from the response status 503"))
  end

  test "exceptions mapped to a status below :failure_status are not reported" do
    {404, headers, _} = assert_error_sent(404, fn -> get(build_conn(), "/missing") end)
    assert TraceGuard.get_report(trace_id(headers)) == {:error, :not_found}
  end

  test ":failure_status can include client errors" do
    configure(failure_status: 400)
    {404, headers, _} = assert_error_sent(404, fn -> get(build_conn(), "/missing") end)
    report = fetch_report!(trace_id(headers))
    assert report["failure"]["exception"] == "TraceGuard.TestApp.NotFoundError"
    assert report["failure"]["plug_status"] == 404
  end

  test "thrown values are captured without exposing their sensitive contents" do
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/throw") end)

    # Plug only wraps :error exceptions in Plug.Conn.WrapperError. Throws and
    # exits reach the endpoint unwrapped, so Phoenix renders them with the
    # conn that entered the endpoint: no TraceGuard header, no before_send.
    # The [:phoenix, :error_rendered] fallback completes the trace instead.
    assert trace_id(headers) == nil
    [%{"trace_id" => id}] = TraceGuard.list_reports()
    report = fetch_report!(id)

    assert report["failure"]["captured_by"] == "phoenix.router_dispatch.exception"
    assert report["request"]["route"] == "/throw"
    assert List.last(event_names(report)) == "phoenix.error_rendered"
    assert report["failure"]["kind"] == "throw"
    assert report["failure"]["exception"] == nil
    refute Jason.encode!(report) =~ "hunter2"
  end

  test "exceptions raised outside the router are captured via [:phoenix, :error_rendered]" do
    conn = build_conn() |> put_req_header("x-test-endpoint-crash", "1")
    ids_before = Enum.map(TraceGuard.list_reports(), & &1["trace_id"])

    {500, _headers, body} = assert_error_sent(500, fn -> get(conn, "/ok") end)
    assert Jason.decode!(body)["errors"]["detail"] == "Internal Server Error"

    # Phoenix renders this error with the conn that entered the endpoint, so
    # the response carries no TraceGuard header; find the report in the store.
    [summary] = Enum.reject(TraceGuard.list_reports(), &(&1["trace_id"] in ids_before))
    report = fetch_report!(summary["trace_id"])

    assert report["failure"]["captured_by"] == "phoenix.error_rendered"
    assert report["failure"]["message"] == "endpoint plug failed"
    assert report["request"]["route"] == nil

    assert event_names(report) == [
             "request.start",
             "phoenix.endpoint.start",
             "phoenix.error_rendered"
           ]

    assert Enum.any?(report["limitations"], &(&1 =~ "outside the router"))
  end

  test "allow-listed headers are captured and sensitive ones redacted" do
    configure(capture_request_headers: ["authorization", "x-api-key", "accept", "user-agent"])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer super-secret-bearer")
      |> put_req_header("x-api-key", "super-secret-key")
      |> put_req_header("user-agent", "curl/8")
      |> put_req_header("cookie", "session=super-secret-cookie")

    {500, headers, _} = assert_error_sent(500, fn -> get(conn, "/crash") end)
    report = fetch_report!(trace_id(headers))

    assert report["request"]["headers"] == %{
             "authorization" => "[REDACTED]",
             "x-api-key" => "[REDACTED]",
             "user-agent" => "curl/8"
           }

    assert report["redaction"]["redacted_values"] == 2
    refute Jason.encode!(report) =~ "super-secret"
  end

  test "path, path params and query strings are only captured when enabled" do
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash?email=a@b.c") end)
    report = fetch_report!(trace_id(headers))
    assert report["request"]["path"] == nil
    refute Jason.encode!(report) =~ "a@b.c"

    configure(capture_path: true, capture_path_params: true, capture_sql: true)
    conn = get(build_conn(), "/users/42?token=abc")
    assert conn.status == 200

    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash?token=abc") end)
    report = fetch_report!(trace_id(headers))
    assert report["request"]["path"] == "/crash"
    assert report["request"]["path_params"] == %{}
    refute Jason.encode!(report) =~ "token=abc"

    assert Enum.any?(
             report["events"],
             &(is_binary(&1["metadata"]["sql"]) and &1["metadata"]["sql"] =~ "SELECT")
           )
  end

  test "path params are redacted when captured" do
    configure(capture_path_params: true, failure_status: 200)
    conn = get(build_conn(), "/users/42")
    report = fetch_report!(trace_id(conn))
    assert report["request"]["route"] == "/users/:id"
    assert report["request"]["path_params"] == %{"id" => "42"}
  end

  test "incoming correlation IDs are validated and kept apart from the trace ID" do
    configure(incoming_header: "x-correlation-id")

    conn = build_conn() |> put_req_header("x-correlation-id", "upstream-123")
    {500, headers, _} = assert_error_sent(500, fn -> get(conn, "/crash") end)
    report = fetch_report!(trace_id(headers))

    assert report["request"]["incoming_id"] == %{
             "header" => "x-correlation-id",
             "value" => "upstream-123"
           }

    assert report["trace_id"] != "upstream-123"

    conn = build_conn() |> put_req_header("x-correlation-id", "<script>alert(1)</script>")
    {500, headers, _} = assert_error_sent(500, fn -> get(conn, "/crash") end)
    assert fetch_report!(trace_id(headers))["request"]["incoming_id"] == nil
  end

  test "events beyond :max_events are dropped and counted" do
    configure(max_events: 5)
    conn = get(build_conn(), "/many/20")
    report = fetch_report!(trace_id(conn))

    assert length(Enum.filter(report["events"], &(&1["name"] == "ecto.query"))) <= 5
    assert report["events_dropped"] > 0
    assert List.last(event_names(report)) == "request.stop"
  end

  test "events from other processes are not attributed to the request" do
    conn = get(build_conn(), "/spawn")
    report = fetch_report!(trace_id(conn))

    sources = for %{"name" => "ecto.query"} = e <- report["events"], do: e["metadata"]["source"]
    assert sources == ["from_request"]
  end

  test "exceptions raised after the response was sent are not reported (documented limitation)" do
    # Phoenix re-raises without rendering because the response is already sent.
    assert_raise TraceGuard.TestApp.BoomError, fn -> get(build_conn(), "/send_then_crash") end
    assert TraceGuard.list_reports() == []
  end

  test "disabled TraceGuard is inert" do
    configure(enabled: false)
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    assert trace_id(headers) == nil
    assert TraceGuard.list_reports() == []
  end
end
