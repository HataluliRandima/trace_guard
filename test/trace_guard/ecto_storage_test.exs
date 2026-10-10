defmodule TraceGuard.Storage.EctoContractTest do
  use TraceGuard.StorageContract,
    storage: {TraceGuard.Storage.Ecto, repo: TraceGuard.TestRepo},
    moduletag: :postgres,
    setup: start_supervised!({TraceGuard.Storage.Ecto, repo: TraceGuard.TestRepo})
end

defmodule TraceGuard.Storage.EctoTest do
  # Real PostgreSQL (TRACE_GUARD_POSTGRES_URL): TraceGuard.Storage.Ecto using
  # the "application's" Repo (TraceGuard.TestRepo). No mocks, no SQLite.
  use ExUnit.Case, async: false

  @moduletag :postgres

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, PostgresSupport, Storage, TestRepo}
  alias TraceGuard.Storage.Ecto, as: EctoStorage

  @endpoint TraceGuard.TestApp.Endpoint

  defp report(extra \\ %{}) do
    Map.merge(
      %{
        "schema" => "traceguard.report/v1",
        "trace_id" => Context.generate_trace_id(),
        "request" => %{"route" => "/r", "method" => "GET"},
        "response" => %{"status" => 500},
        "events" => []
      },
      extra
    )
  end

  defp use_ecto(opts \\ []) do
    adapter_opts = Keyword.merge([repo: TestRepo], opts)
    pid = start_supervised!({EctoStorage, adapter_opts}, restart: :temporary)
    configure(storage: {EctoStorage, adapter_opts}, max_pending_reports: 10, max_reports: 50)
    TraceGuard.clear_reports()
    {pid, adapter_opts}
  end

  defp submit!(r) do
    assert {:ok, :queued} = Storage.put(r)
    assert {:ok, ^r} = TraceGuard.await_report(r["trace_id"], 5_000)
    r
  end

  defp sql(query, params \\ []), do: Ecto.Adapters.SQL.query!(TestRepo, query, params, log: false)

  defp app_orders_count, do: hd(hd(sql("SELECT count(*) FROM app_orders").rows))

  test "a real failure is stored redacted: raw table contents contain no secrets" do
    use_ecto()

    configure(
      storage: {EctoStorage, repo: TestRepo},
      capture_request_headers: ["authorization", "x-api-key"],
      capture_sql: true
    )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer pg-secret-token")
      |> put_req_header("x-api-key", "pg-secret-key")

    {500, headers, _} =
      assert_error_sent(500, fn -> get(conn, "/crash?password=pg-secret-pw") end)

    id = trace_id(headers)
    {:ok, report} = TraceGuard.await_report(id, 5_000)
    assert report["request"]["headers"]["authorization"] == "[REDACTED]"

    # Every column of every row, as PostgreSQL renders it.
    raw =
      sql("SELECT t::text FROM trace_guard_reports t").rows |> List.flatten() |> Enum.join("\n")

    assert raw =~ id

    for secret <- [
          "pg-secret-token",
          "pg-secret-key",
          "pg-secret-pw",
          "fake_gateway_key_123",
          "super-secret-param",
          "alice@example.com"
        ] do
      refute raw =~ secret, "#{secret} reached PostgreSQL"
    end
  end

  test "lookup by trace ID and by every supported filter (filtered in SQL)" do
    use_ecto()

    a =
      submit!(
        report(%{
          "request" => %{
            "route" => "/a",
            "method" => "POST",
            "request_id" => "req-a",
            "incoming_id" => %{"header" => "x-correlation-id", "value" => "corr-a"}
          }
        })
      )

    b =
      submit!(
        report(%{
          "request" => %{"route" => "/b", "method" => "GET"},
          "response" => %{"status" => 503}
        })
      )

    assert {:ok, ^a} = TraceGuard.get_report(a["trace_id"])
    assert [%{"trace_id" => id_a}] = TraceGuard.list_reports(incoming_id: "corr-a")
    assert id_a == a["trace_id"]
    assert [%{"trace_id" => ^id_a}] = TraceGuard.list_reports(request_id: "req-a")
    assert [%{"trace_id" => ^id_a}] = TraceGuard.list_reports(route: "/a", method: "POST")
    assert [%{"trace_id" => id_b}] = TraceGuard.list_reports(status: 503)
    assert id_b == b["trace_id"]
    assert [] = TraceGuard.list_reports(incoming_id: "corr")
    # A nil-valued filter matches rows whose column is NULL.
    assert [%{"trace_id" => ^id_b}] = TraceGuard.list_reports(incoming_id: nil)

    # The adapter's SQL path and the generic path agree.
    criteria = [{"route", "/a"}]

    assert EctoStorage.list_matching(criteria, repo: TestRepo) ==
             Enum.filter(EctoStorage.list(repo: TestRepo), &(&1["route"] == "/a"))
  end

  test "await_report/2 and report_status/1 with stored reports" do
    use_ecto()
    r = report()
    assert {:ok, :queued} = Storage.put(r)
    assert {:ok, ^r} = TraceGuard.await_report(r["trace_id"], 5_000)
    assert TraceGuard.report_status(r["trace_id"]) == :stored
    assert TraceGuard.report_status(Context.generate_trace_id()) == :unknown
  end

  test "queue overflow: the writer's mailbox stays bounded and refusals are explicit" do
    {pid, _} = use_ecto()
    handler = attach_report_events()
    :sys.suspend(pid)

    results =
      1..100
      |> Task.async_stream(
        fn _ ->
          r = report()
          {r["trace_id"], Storage.put(r)}
        end,
        max_concurrency: 25
      )
      |> Enum.map(fn {:ok, x} -> x end)

    assert {:message_queue_len, 10} = Process.info(pid, :message_queue_len)
    {admitted, refused} = Enum.split_with(results, fn {_, r} -> r == {:ok, :queued} end)
    assert length(admitted) == 10

    # A writer that doesn't answer (here suspended; in production stuck in a
    # slow statement) is reported as busy, with its queue, not as down.
    assert %{writer_running: true, writer_busy: true, pending: 10} = TraceGuard.report_stats()

    for {id, _} <- refused do
      assert_receive {:report_event, {:dropped, :overloaded}, ^id}
      assert TraceGuard.report_status(id) == {:dropped, :overloaded}
    end

    :sys.resume(pid)
    for {id, _} <- admitted, do: assert_receive({:report_event, :stored, ^id}, 5_000)
    assert %{writer_running: true, writer_busy: false, pending: 0} = TraceGuard.report_stats()
    :telemetry.detach(handler)
  end

  @tag :capture_log
  test "database not available at startup (repo not started), then recovers" do
    start_supervised!({EctoStorage, repo: TraceGuard.TestRepoNeverStarted}, restart: :temporary)
    configure(storage: {EctoStorage, repo: TraceGuard.TestRepoNeverStarted})
    handler = attach_report_events()

    r = report()
    {:ok, :queued} = Storage.put(r)
    id = r["trace_id"]
    assert_receive {:report_event, {:dropped, {:ecto_error, :repo_not_started}}, ^id}, 5_000
    assert TraceGuard.report_status(id) == {:dropped, {:ecto_error, :repo_not_started}}
    assert TraceGuard.get_report(id) == {:error, :unavailable}
    assert TraceGuard.list_reports() == []

    # The application's Repo comes up later: the same writer now succeeds.
    start_supervised!(TraceGuard.TestRepoNeverStarted)
    r2 = submit!(report())
    assert TraceGuard.report_status(r2["trace_id"]) == :stored
    assert %{write_errors: 1, last_error: :repo_not_started} = TraceGuard.report_stats()
    :telemetry.detach(handler)
  end

  @tag :capture_log
  test "database unavailable during operation: writes dropped, requests unaffected, then recovery" do
    {pid, _} = use_ecto()
    admin = PostgresSupport.admin!()
    db = PostgresSupport.database()
    handler = attach_report_events()

    on_exit(fn ->
      admin = PostgresSupport.admin!()
      Postgrex.query!(admin, ~s{ALTER DATABASE "#{db}" ALLOW_CONNECTIONS true}, [])
    end)

    # Outage: no new connections, existing ones killed.
    Postgrex.query!(admin, ~s{ALTER DATABASE "#{db}" ALLOW_CONNECTIONS false}, [])

    Postgrex.query!(
      admin,
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
      [db]
    )

    {500, headers, body} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
    id = trace_id(headers)

    assert_receive {:report_event, {:dropped, {:ecto_error, reason}}, ^id}, 15_000
    assert reason in [:connection, :admin_shutdown, :cannot_connect_now, :timeout]
    assert Process.alive?(pid)
    assert TraceGuard.get_report(id) == {:error, :unavailable}

    # Recovery: the pool reconnects (DBConnection backoff), writes succeed.
    Postgrex.query!(admin, ~s{ALTER DATABASE "#{db}" ALLOW_CONNECTIONS true}, [])
    recovered = recover_until_stored(30)
    assert TraceGuard.report_status(recovered) == :stored
    assert TraceGuard.report_stats().write_errors >= 1
    :telemetry.detach(handler)
  end

  # Submits until one report is stored; bounded by `attempts`. Each attempt
  # waits for that report's own outcome event.
  defp recover_until_stored(0), do: flunk("writes did not recover")

  defp recover_until_stored(attempts) do
    r = report()
    id = r["trace_id"]
    {:ok, :queued} = Storage.put(r)

    receive do
      {:report_event, :stored, ^id} -> id
      {:report_event, {:dropped, _}, ^id} -> recover_until_stored(attempts - 1)
    after
      10_000 -> flunk("no outcome for #{id}")
    end
  end

  test "retention by count and by age; unrelated tables are untouched" do
    sql("INSERT INTO app_orders (reference) VALUES ('order-1'), ('order-2')")
    before_orders = app_orders_count()
    use_ecto(max_reports: 3, max_age: 3_600_000)

    reports = for _ <- 1..5, do: submit!(report())
    assert length(TraceGuard.list_reports()) == 3
    assert TraceGuard.get_report(hd(reports)["trace_id"]) == {:error, :not_found}

    newest = List.last(reports)["trace_id"]

    sql(
      "UPDATE trace_guard_reports SET inserted_at = now() - interval '2 hours' WHERE trace_id = $1",
      [newest]
    )

    assert {:ok, 1} = EctoStorage.cleanup()
    assert TraceGuard.get_report(newest) == {:error, :not_found}

    assert :ok = TraceGuard.clear_reports()
    assert TraceGuard.list_reports() == []
    assert app_orders_count() == before_orders
  end

  test "corrupt or incompatible stored data is reported as such, never returned" do
    use_ecto()
    good = submit!(report())
    bad = submit!(report())
    other = submit!(report())

    sql("UPDATE trace_guard_reports SET report = '[1, 2]'::jsonb WHERE trace_id = $1", [
      bad["trace_id"]
    ])

    sql(
      ~s|UPDATE trace_guard_reports SET report = '{"schema": "something/v9"}'::jsonb, summary = '{}'::jsonb WHERE trace_id = $1|,
      [other["trace_id"]]
    )

    assert TraceGuard.get_report(bad["trace_id"]) == {:error, :corrupt}
    assert TraceGuard.get_report(other["trace_id"]) == {:error, :corrupt}
    assert TraceGuard.report_status(bad["trace_id"]) == {:error, :corrupt}

    ids = Enum.map(TraceGuard.list_reports(), & &1["trace_id"])
    assert good["trace_id"] in ids
    refute other["trace_id"] in ids
  end

  @tag :capture_log
  test "a missing table (migration not run) drops writes explicitly and reads return unavailable" do
    use_ecto(prefix: "schema_without_table")
    handler = attach_report_events()
    r = report()
    {:ok, :queued} = Storage.put(r)
    id = r["trace_id"]

    assert_receive {:report_event, {:dropped, {:ecto_error, code}}, ^id}, 5_000
    assert code in [:undefined_table, :invalid_schema_name]
    assert TraceGuard.get_report(id) == {:error, :unavailable}
    :telemetry.detach(handler)
  end

  test "concurrent writes and reads" do
    use_ecto()
    configure(storage: {EctoStorage, repo: TestRepo}, max_pending_reports: 200, max_reports: 500)

    ids =
      1..100
      |> Task.async_stream(
        fn _ ->
          r = report()
          {:ok, :queued} = Storage.put(r)
          {:ok, ^r} = TraceGuard.await_report(r["trace_id"], 10_000)
          # Concurrent reads while others are still writing.
          {:ok, _} = TraceGuard.get_report(r["trace_id"])
          _ = TraceGuard.list_reports(route: "/r")
          r["trace_id"]
        end,
        max_concurrency: 25,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert length(Enum.uniq(ids)) == 100
    assert hd(hd(sql("SELECT count(*) FROM trace_guard_reports").rows)) == 100
  end

  test "writer restart: committed reports survive, queued ones become :lost" do
    {pid, opts} = use_ecto()
    kept = submit!(report())

    :sys.suspend(pid)

    queued =
      for _ <- 1..3,
          do:
            (
              r = report()
              {:ok, :queued} = Storage.put(r)
              r["trace_id"]
            )

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    start_supervised!({EctoStorage, opts}, restart: :temporary, id: :ecto_again)
    for id <- queued, do: assert(TraceGuard.report_status(id) == {:dropped, :lost})
    assert TraceGuard.get_report(kept["trace_id"]) == {:ok, kept}
  end

  test "the TraceGuard application restarts and reads its reports back from PostgreSQL" do
    use_ecto()
    kept = submit!(report())
    :ok = stop_supervised(EctoStorage)

    # A full restart of TraceGuard's own application, with the Ecto adapter
    # configured at boot (as an application would configure it).
    previous = Application.get_env(:trace_guard, :storage)
    Application.put_env(:trace_guard, :storage, {EctoStorage, repo: TestRepo})

    on_exit(fn ->
      Application.stop(:trace_guard)

      if previous,
        do: Application.put_env(:trace_guard, :storage, previous),
        else: Application.delete_env(:trace_guard, :storage)

      {:ok, _} = Application.ensure_all_started(:trace_guard)
    end)

    :ok = Application.stop(:trace_guard)
    {:ok, _} = Application.ensure_all_started(:trace_guard)

    assert is_pid(Process.whereis(EctoStorage))
    assert TraceGuard.get_report(kept["trace_id"]) == {:ok, kept}
    assert TraceGuard.report_status(kept["trace_id"]) == :stored
  end

  test "TraceGuard's own queries are invisible to the application's Ecto telemetry" do
    use_ecto()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, :repo_events},
      [:trace_guard, :test_repo, :query],
      fn _event, _measurements, meta, _ -> send(test_pid, {:repo_query, meta.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, :repo_events}) end)
    r = submit!(report())
    {:ok, _} = TraceGuard.get_report(r["trace_id"])
    _ = TraceGuard.list_reports(route: "/r")

    refute_received {:repo_query, _}
  end

  test "the adapter refuses non-PostgreSQL repos and invalid options" do
    Process.flag(:trap_exit, true)

    for opts <- [
          [],
          [repo: NotARepo],
          [repo: TestRepo, max_reports: 0],
          [repo: TestRepo, prefx: "x"],
          [repo: TestRepo, prefix: :atom]
        ] do
      assert {:error, {%ArgumentError{}, _}} = EctoStorage.start_link(opts)
    end
  end

  test "migration up/down in a separate schema prefix" do
    sql("CREATE SCHEMA IF NOT EXISTS tg_prefixed")
    on_exit(fn -> sql("DROP SCHEMA IF EXISTS tg_prefixed CASCADE") end)

    defmodule PrefixedMigration do
      use Ecto.Migration
      def up, do: TraceGuard.Storage.Ecto.Migration.up(version: 1, prefix: "tg_prefixed")
      def down, do: TraceGuard.Storage.Ecto.Migration.down(version: 1, prefix: "tg_prefixed")
    end

    :ok = Ecto.Migrator.up(TestRepo, 990_001, PrefixedMigration, log: false)
    use_ecto(prefix: "tg_prefixed")
    r = submit!(report())
    assert [[1]] = sql("SELECT count(*) FROM tg_prefixed.trace_guard_reports").rows

    assert [[0]] =
             sql("SELECT count(*) FROM public.trace_guard_reports WHERE trace_id = $1", [
               r["trace_id"]
             ]).rows

    :ok = Ecto.Migrator.down(TestRepo, 990_001, PrefixedMigration, log: false)
    assert [[nil]] = sql("SELECT to_regclass('tg_prefixed.trace_guard_reports')::text").rows
  end
end
