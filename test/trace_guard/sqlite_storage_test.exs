defmodule TraceGuard.Storage.SQLiteContractTest do
  use TraceGuard.StorageContract,
    storage: {TraceGuard.Storage.SQLite, database: TraceGuard.SQLiteHelpers.db_path("contract")},
    setup:
      (fn ->
         import TraceGuard.SQLiteHelpers
         start_sqlite!("contract")
       end).()
end

defmodule TraceGuard.Storage.SQLiteTest do
  # The persistent adapter: restarts, redaction on disk, retention, outages.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  import TraceGuard.SQLiteHelpers
  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, Storage}
  alias TraceGuard.Storage.SQLite

  @endpoint TraceGuard.TestApp.Endpoint

  defp report(extra \\ %{}),
    do: Map.merge(%{"trace_id" => Context.generate_trace_id(), "events" => []}, extra)

  defp use_sqlite(name, opts \\ []) do
    {path, opts, pid} = start_sqlite!(name, opts)
    configure(storage: {SQLite, opts}, max_pending_reports: 5, max_reports: 50)
    {path, opts, pid}
  end

  defp restart_writer(pid, opts) do
    ref = Process.monitor(pid)
    :ok = stop_supervised(SQLite)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    start_supervised!({SQLite, opts}, restart: :temporary)
  end

  test "a stored report survives a writer restart (connection re-opened from the file)" do
    {_path, opts, pid} = use_sqlite("restart")
    r = submit!(report(%{"request" => %{"route" => "/persisted"}}))

    restart_writer(pid, opts)

    assert TraceGuard.get_report(r["trace_id"]) == {:ok, r}
    assert TraceGuard.report_status(r["trace_id"]) == :stored
    assert [%{"route" => "/persisted"}] = TraceGuard.list_reports()
  end

  test "only redacted data reaches the database file" do
    {path, _opts, _pid} = use_sqlite("redaction")

    configure(
      storage: {SQLite, database: path},
      capture_request_headers: ["authorization", "x-api-key"],
      capture_sql: true
    )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer disk-secret-token")
      |> put_req_header("x-api-key", "disk-secret-key")

    {500, headers, _} =
      assert_error_sent(500, fn -> get(conn, "/crash?password=disk-secret-pw") end)

    id = trace_id(headers)
    {:ok, report} = TraceGuard.await_report(id, 1_000)

    [[report_json, summary_json]] =
      raw_rows(path, "SELECT report, summary FROM trace_guard_reports WHERE trace_id = ?1", [id])

    assert Jason.decode!(report_json) == report
    assert Jason.decode!(summary_json) == Storage.summary(report)

    # Every byte on disk (database, WAL and shared-memory files).
    disk = Enum.map_join(["", "-wal", "-shm"], &(File.read(path <> &1) |> elem(1) |> to_string()))
    assert disk =~ id

    for secret <- [
          "disk-secret-token",
          "disk-secret-key",
          "disk-secret-pw",
          "fake_gateway_key_123",
          "super-secret-param"
        ] do
      refute disk =~ secret, "#{secret} written to disk"
    end
  end

  test "retention by count, and cleanup by age" do
    {path, opts, _pid} = use_sqlite("retention", max_reports: 3, max_age: 60_000)
    reports = for i <- 1..5, do: submit!(report(%{"n" => i}))

    assert length(TraceGuard.list_reports()) == 3
    assert TraceGuard.get_report(hd(reports)["trace_id"]) == {:error, :not_found}
    assert TraceGuard.report_stats().evicted == 2

    # Age the newest row explicitly, then clean up: only it goes.
    newest = List.last(reports)["trace_id"]
    raw_exec(path, "UPDATE trace_guard_reports SET stored_at = 0 WHERE trace_id = '#{newest}'")
    assert {:ok, 1} = SQLite.cleanup()
    assert TraceGuard.get_report(newest) == {:error, :not_found}
    assert length(TraceGuard.list_reports()) == 2
    assert opts[:max_age] == 60_000
  end

  test "a locked database: the queue stays bounded, failures are dropped explicitly, then it recovers" do
    {path, _opts, pid} = use_sqlite("outage", busy_timeout: 20)
    handler = attach_report_events()

    # Another connection holds the write lock: every write fails after 20 ms.
    {:ok, locker} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(locker, "BEGIN EXCLUSIVE")

    results =
      1..200
      |> Task.async_stream(
        fn _ ->
          r = report()
          {r["trace_id"], Storage.put(r)}
        end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, r} -> r end)

    {_, queue} = Process.info(pid, :message_queue_len)
    assert queue <= 5

    {admitted, refused} = Enum.split_with(results, fn {_, r} -> r == {:ok, :queued} end)
    assert length(admitted) >= 5
    assert Enum.all?(refused, fn {_, r} -> r == {:error, :overloaded} end)

    # Each admitted report fails explicitly with the SQLite error.
    for {id, _} <- admitted do
      assert_receive {:report_event, {:dropped, {:sqlite_error, message}}, ^id}, 5_000
      assert message =~ "locked"
      assert {:dropped, {:sqlite_error, _}} = TraceGuard.report_status(id)
    end

    for {id, _} <- refused, do: assert(TraceGuard.report_status(id) == {:dropped, :overloaded})

    :ok = Exqlite.Sqlite3.execute(locker, "ROLLBACK")
    Exqlite.Sqlite3.close(locker)
    :telemetry.detach(handler)

    r = submit!(report())
    assert TraceGuard.report_status(r["trace_id"]) == :stored
    assert TraceGuard.report_stats().write_errors == length(admitted)
  end

  @tag :capture_log
  test "a database that cannot be opened: reports are dropped, reads return, requests are unaffected" do
    blocker = db_path("not_a_directory")
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(blocker, "a file, not a directory")
    path = Path.join(blocker, "reports.db")
    start_supervised!({SQLite, database: path}, restart: :temporary)
    configure(storage: {SQLite, database: path})
    handler = attach_report_events()

    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    id = trace_id(headers)

    assert_receive {:report_event, {:dropped, {:sqlite, :unavailable}}, ^id}
    assert TraceGuard.report_status(id) == {:dropped, {:sqlite, :unavailable}}
    assert TraceGuard.get_report(id) == {:error, :unavailable}
    assert TraceGuard.list_reports() == []
    assert %{available: false} = TraceGuard.report_stats()
    :telemetry.detach(handler)
  end

  test "corrupt rows are reported as corrupt, never as reports" do
    {path, _opts, _pid} = use_sqlite("corrupt")
    good = submit!(report())
    bad = submit!(report())

    raw_exec(
      path,
      "UPDATE trace_guard_reports SET report = '{not json', summary = '{' WHERE trace_id = '#{bad["trace_id"]}'"
    )

    assert TraceGuard.get_report(bad["trace_id"]) == {:error, :corrupt}
    assert TraceGuard.report_status(bad["trace_id"]) == {:error, :corrupt}
    assert [%{"trace_id" => id}] = TraceGuard.list_reports()
    assert id == good["trace_id"]
    # get_report + report_status + list each hit a corrupt row.
    assert TraceGuard.report_stats().corrupt_reads == 3
  end

  test "submissions queued in a writer that dies are recorded as lost, by trace ID" do
    {_path, opts, pid} = use_sqlite("lost")
    :sys.suspend(pid)

    ids =
      for _ <- 1..3,
          do:
            (
              r = report()
              {:ok, :queued} = Storage.put(r)
              r["trace_id"]
            )

    for id <- ids, do: assert(TraceGuard.report_status(id) in [:pending, {:error, :unavailable}])

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    start_supervised!({SQLite, opts}, restart: :temporary, id: :sqlite_again)

    for id <- ids, do: assert(TraceGuard.report_status(id) == {:dropped, :lost})
  end

  @tag :capture_log
  test "a database with a newer schema version is left untouched" do
    path = db_path("future_schema")
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    File.mkdir_p!(Path.dirname(path))
    raw_exec(path, "PRAGMA user_version = 99")

    start_supervised!({SQLite, database: path}, restart: :temporary)
    configure(storage: {SQLite, database: path})

    assert %{available: false} = TraceGuard.report_stats()
    assert raw_rows(path, "PRAGMA user_version") == [[99]]
    assert raw_rows(path, "SELECT name FROM sqlite_master WHERE type = 'table'") == []
  end

  describe "release hardening (Phase 5)" do
    test "a database file the adapter creates is readable by its owner only" do
      {path, _opts, _pid} = use_sqlite("permissions")
      submit!(report())

      for file <- [path, path <> "-wal", path <> "-shm"], File.exists?(file) do
        assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600, "#{file} is not 0600"
      end
    end

    test "an existing file keeps the permissions it was given" do
      path = db_path("existing_permissions")
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
      File.mkdir_p!(Path.dirname(path))
      raw_exec(path, "PRAGMA user_version = 0")
      File.chmod!(path, 0o640)

      start_supervised!({SQLite, database: path}, restart: :temporary)
      configure(storage: {SQLite, database: path})
      assert %{available: true} = TraceGuard.report_stats()
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o640
    end

    test "deleted, cleared and cleaned-up reports leave no trace in the files" do
      {path, _opts, _pid} = use_sqlite("secure_delete", max_age: 60_000)

      [a, b, c] =
        for _ <- 1..3,
            do: submit!(report(%{"marker" => "MARKER-#{System.unique_integer([:positive])}"}))

      disk = fn ->
        Enum.map_join(["", "-wal"], &(File.read(path <> &1) |> elem(1) |> to_string()))
      end

      assert :ok = TraceGuard.delete_report(a["trace_id"])
      refute disk.() =~ a["marker"]

      raw_exec(
        path,
        "UPDATE trace_guard_reports SET stored_at = 0 WHERE trace_id = '#{b["trace_id"]}'"
      )

      assert {:ok, 1} = SQLite.cleanup()
      refute disk.() =~ b["marker"]

      assert disk.() =~ c["marker"]
      assert :ok = TraceGuard.clear_reports()
      refute disk.() =~ c["marker"]
    end

    test "invalid or unknown options are rejected at start" do
      Process.flag(:trap_exit, true)

      for opts <- [
            [database: db_path("bad1"), max_reprots: 3],
            [database: ""],
            [max_reports: 3],
            [database: db_path("bad2"), max_reports: 0],
            [database: db_path("bad3"), busy_timeout: -1]
          ] do
        assert {:error, {%ArgumentError{}, _}} = SQLite.start_link(opts)
      end
    end
  end

  defp submit!(r) do
    assert {:ok, :queued} = Storage.put(r)
    assert {:ok, ^r} = TraceGuard.await_report(r["trace_id"], 2_000)
    r
  end
end
