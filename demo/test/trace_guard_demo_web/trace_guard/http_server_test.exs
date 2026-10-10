defmodule TraceGuardDemoWeb.HttpServerTest do
  # Runs the real endpoint behind a real Bandit HTTP server and talks to it
  # over TCP, so the request is handled by Bandit's own processes and the
  # re-raised exception reaches Bandit as it would in production.
  use TraceGuardDemo.DataCase, async: false

  # Bandit logs the re-raised exception, as it should; keep test output clean.
  @moduletag :capture_log

  import TraceGuardDemo.Fixtures

  setup do
    TraceGuard.clear_reports()
    product!()

    {:ok, server} =
      Bandit.start_link(
        plug: TraceGuardDemoWeb.Endpoint,
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    {:ok, _} = Application.ensure_all_started(:inets)
    %{base: "http://127.0.0.1:#{port}"}
  end

  defp request(method, url, headers \\ [], body \\ nil) do
    headers = for {k, v} <- headers, k != "content-type", do: {~c"#{k}", ~c"#{v}"}

    req =
      if body,
        do: {~c"#{url}", headers, ~c"application/json", body},
        else: {~c"#{url}", headers}

    {:ok, {{_, status, _}, resp_headers, resp_body}} =
      :httpc.request(method, req, [], body_format: :binary)

    {status, resp_headers, resp_body}
  end

  test "failure, success and error-status requests over real HTTP", %{base: base} do
    {500, h1, body} = request(:post, base <> "/api/checkout", checkout_headers(), checkout_body())
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}

    {200, h2, _} = request(:get, base <> "/api/products")
    {503, h3, _} = request(:post, base <> "/api/inventory/sync", [], "{}")

    [first, second, third] = Enum.map([h1, h2, h3], &trace_id/1)

    report = fetch_report!(first)
    assert ["begin", _, _, _, "rollback"] = ecto_sql(report)
    assert report["failure"]["exception"] == "TraceGuardDemo.Payments.GatewayError"
    {:ok, json} = TraceGuard.export_json(first)
    for secret <- secrets(), do: refute(json =~ secret)

    assert TraceGuard.get_report(second) == {:error, :not_found}

    report = fetch_report!(third)
    assert report["outcome"] == "error_status"
    assert [sql] = ecto_sql(report)
    assert sql =~ "FROM \"products\""

    # Wrapped tasks under Bandit: the child's failure and queries are kept.
    {500, h4, _} = request(:post, base <> "/api/inventory/reconcile", [], "{}")
    assert trace_id(h4) == nil
    reconcile = fetch_report_for_route!("/api/inventory/reconcile")
    assert reconcile["tasks"]["processes"] == 2
    assert Enum.any?(reconcile["events"], &(&1["name"] == "task.exception"))

    # GenServer propagation under Bandit: the server's crash is in the report.
    product!(%{sku: "TG-002", name: "Span Wrench", price_cents: 1_250, stock: 5})

    Ecto.Adapters.SQL.Sandbox.allow(
      TraceGuardDemo.Repo,
      self(),
      Process.whereis(TraceGuardDemo.Pricing)
    )

    {500, _, _} =
      request(:post, base <> "/api/quote", [], Jason.encode!(%{sku: "TG-002", qty: 1}))

    quote_report = fetch_report_for_route!("/api/quote")
    assert Enum.any?(quote_report["events"], &(&1["name"] == "genserver.call.exception"))

    # The dev endpoint serves the same report over HTTP.
    {200, _, served} = request(:get, base <> "/dev/traces/" <> first)
    assert Jason.decode!(served)["trace_id"] == first
  end
end
