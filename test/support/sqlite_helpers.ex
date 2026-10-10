defmodule TraceGuard.SQLiteHelpers do
  @moduledoc false
  # Shared setup for TraceGuard.Storage.SQLite tests.

  import ExUnit.Callbacks

  def db_path(name),
    do: Path.join([System.tmp_dir!(), "trace_guard_test", "#{name}.db"])

  @doc "Starts the SQLite adapter on a fresh database file and selects it."
  def start_sqlite!(name, opts \\ []) do
    path = db_path(name)
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    opts = Keyword.put(opts, :database, path)
    pid = start_supervised!({TraceGuard.Storage.SQLite, opts}, restart: :temporary)
    {path, opts, pid}
  end

  @doc "Raw rows read with an independent connection (bypassing the adapter)."
  def raw_rows(path, sql, params \\ []) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  def raw_exec(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(conn, sql)
    Exqlite.Sqlite3.close(conn)
  end
end
