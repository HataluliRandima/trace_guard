defmodule TraceGuard.DebugErrorsTest do
  # With `debug_errors: true`, Plug.Debugger renders the error page before
  # Phoenix.Endpoint.RenderErrors, which then skips rendering (and the
  # [:phoenix, :error_rendered] event) because the response is already sent.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  @endpoint TraceGuard.TestApp.DebugEndpoint

  setup do
    configure()
    :ok
  end

  test "router exceptions are still captured and re-raised" do
    {500, headers, body} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)

    # Plug.Debugger's page, not the JSON error view, proves the debugger ran.
    assert body =~ "BoomError"
    refute body =~ ~s("errors")

    report = fetch_report!(trace_id(headers))

    assert report["failure"]["exception"] == "TraceGuard.TestApp.BoomError"
    assert report["failure"]["captured_by"] == "phoenix.router_dispatch.exception"
    assert List.last(event_names(report)) == "request.stop"
  end

  # Documented limitation: Plug.Debugger renders endpoint-level failures with
  # the conn that entered the endpoint, so neither TraceGuard's before_send
  # callback nor [:phoenix, :error_rendered] runs.
  test "failures outside the router are not reported" do
    conn = Plug.Conn.put_req_header(build_conn(), "x-test-endpoint-crash", "1")
    {500, _headers, body} = assert_error_sent(500, fn -> get(conn, "/ok") end)

    assert body =~ "endpoint plug failed"
    assert TraceGuard.list_reports() == []

    # The unfinished context is replaced by the next request in this process.
    conn = get(build_conn(), "/ok")
    assert conn.status == 200
    assert TraceGuard.current_trace_id() == nil
  end
end
