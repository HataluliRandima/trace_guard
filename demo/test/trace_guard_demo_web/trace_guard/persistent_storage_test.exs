defmodule TraceGuardDemoWeb.PersistentStorageTest do
  # TraceGuard.Storage.SQLite with the real demo application: a failing
  # checkout's report is written to its own SQLite file (separate from the
  # demo's Ecto database), contains no secrets, and survives a restart.
  use TraceGuardDemoWeb.ConnCase, async: false

  import TraceGuardDemo.Fixtures

  @db Path.join(System.tmp_dir!(), "trace_guard_demo_persistent_test.db")

  setup do
    for suffix <- ["", "-wal", "-shm"], do: File.rm(@db <> suffix)
    start_supervised!({TraceGuard.Storage.SQLite, database: @db}, restart: :temporary)
    previous = Application.get_env(:trace_guard, :storage)
    put_storage({TraceGuard.Storage.SQLite, database: @db})

    on_exit(fn -> put_storage(previous || TraceGuard.ReportStore) end)
    product!()
    :ok
  end

  defp put_storage(storage) do
    :trace_guard
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "Elixir.") end)
    |> Keyword.put(:storage, storage)
    |> TraceGuard.Config.put!()
  end

  test "a real failure is persisted redacted and survives a storage restart", %{conn: conn} do
    conn = Enum.reduce(checkout_headers(), conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    {500, headers, _} =
      assert_error_sent(500, fn -> post(conn, ~p"/api/checkout", checkout_body()) end)

    id = trace_id(headers)
    report = fetch_report!(id, 2_000)

    disk = Enum.map_join(["", "-wal", "-shm"], &(File.read(@db <> &1) |> elem(1) |> to_string()))
    assert disk =~ id
    for secret <- secrets(), do: refute(disk =~ secret, "#{secret} written to disk")

    :ok = stop_supervised(TraceGuard.Storage.SQLite)
    start_supervised!({TraceGuard.Storage.SQLite, database: @db}, restart: :temporary)

    assert TraceGuard.get_report(id) == {:ok, report}
    assert TraceGuard.report_status(id) == :stored
  end
end
