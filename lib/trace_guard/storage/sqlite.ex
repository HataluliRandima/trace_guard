if Code.ensure_loaded?(Exqlite.Sqlite3) do
  defmodule TraceGuard.Storage.SQLite do
    @moduledoc """
    A persistent `TraceGuard.Storage` adapter for local development and
    testing: reports are kept in a SQLite file and survive restarts.

    Requires the optional dependency `{:exqlite, "~> 0.42"}` (the driver
    behind `ecto_sqlite3`). It opens its own database file and needs no Ecto
    repo.

        config :trace_guard,
          storage: {TraceGuard.Storage.SQLite, database: "priv/trace_guard_reports.db"}

    ## Options

      * `:database` (required): path of the SQLite file (created if missing).
      * `:max_reports`: retained reports (default: the `:max_reports` config).
      * `:max_age`: if set, reports older than this many milliseconds are
        removed by cleanup (wall-clock time, so it survives restarts).
      * `:cleanup_interval`: periodic cleanup in ms (default 60_000).
      * `:busy_timeout`: how long a write waits for a SQLite lock, in ms
        (default 1_000).
      * `:call_timeout`: default timeout for reads, in ms (default 5_000).

    ## Writes never block requests

    `put/2` runs in the request process and only does admission (an
    `:atomics` increment against `:max_pending_reports`) and a `send/2` to
    the single writer process. That is the same bounded-queue contract as
    `TraceGuard.ReportStore`, so the writer's mailbox never holds more than
    `:max_pending_reports` reports, even while the database is locked or
    missing. The writer does the I/O.

    ## Storage format (schema version 1)

        CREATE TABLE trace_guard_reports (
          trace_id  TEXT PRIMARY KEY NOT NULL,  -- 32 hex chars
          seq       INTEGER NOT NULL,           -- insertion order (newest = highest)
          stored_at INTEGER NOT NULL,           -- unix ms when written
          summary   TEXT NOT NULL,              -- JSON, TraceGuard.Storage.summary/1
          report    TEXT NOT NULL               -- JSON, the redacted report
        );
        CREATE INDEX trace_guard_reports_seq ON trace_guard_reports (seq);

    The version is kept in `PRAGMA user_version`. A database with a newer
    version is not touched; the adapter reports itself unavailable instead.
    Every statement uses bound parameters.

    ## Transactions, retention and recovery

      * Each report is one transaction: upsert by `trace_id` (a resubmitted
        trace replaces its row), then delete everything but the newest
        `:max_reports` rows. A report is announced as stored only after
        `COMMIT`.
      * Any write error (locked database, I/O error, encoding failure) rolls
        back and emits `[:trace_guard, :report, :dropped]` with
        `{:sqlite_error, message}` or `:serialization_error`, never a false
        `:stored`.
      * If the database can't be opened (at start, or after an error closed
        it), the writer keeps running with no connection. Admitted reports are
        dropped with reason `{:sqlite, :unavailable}`, and it retries opening
        every second. Requests are never affected.
      * After a writer restart, committed reports are read back from the
        file. Reports admitted but not yet committed are recorded as `:lost`.
      * Rows that fail to decode return `{:error, :corrupt}` from `get` and
        are skipped by `list`. Each such read is counted in `stats` as
        `:corrupt_reads`.
      * `cleanup/0` applies `:max_age` and `:max_reports` on demand. It also
        runs every `:cleanup_interval`.

    WAL journal mode with `synchronous = NORMAL`: a power loss can lose the
    most recent commits but doesn't corrupt the file.
    """

    @behaviour TraceGuard.Storage

    use GenServer

    require Logger

    alias Exqlite.Sqlite3
    alias TraceGuard.{Config, Storage}

    @schema_version 1
    @admission {__MODULE__, :admission}

    @schema [
      """
      CREATE TABLE IF NOT EXISTS trace_guard_reports (
        trace_id TEXT PRIMARY KEY NOT NULL,
        seq INTEGER NOT NULL,
        stored_at INTEGER NOT NULL,
        summary TEXT NOT NULL,
        report TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS trace_guard_reports_seq ON trace_guard_reports (seq)"
    ]

    @doc false
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @doc """
    Applies `:max_age` and `:max_reports` now. Returns
    `{:ok, deleted_rows}` or `{:error, :unavailable}`.
    """
    @spec cleanup(timeout()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
    def cleanup(timeout \\ 5_000), do: call(:cleanup, timeout: timeout)

    ## TraceGuard.Storage callbacks (put/2 runs in the calling process)

    @impl Storage
    def put(%{"trace_id" => _} = report, _opts) do
      case :persistent_term.get(@admission, nil) do
        {pid, pending} ->
          if Process.alive?(pid), do: admit(pid, pending, report), else: {:error, :unavailable}

        nil ->
          {:error, :unavailable}
      end
    end

    defp admit(pid, pending, report) do
      if :atomics.add_get(pending, 1, 1) <= Config.get().max_pending_reports do
        send(pid, {:put, report})
        {:ok, :queued}
      else
        :atomics.sub(pending, 1, 1)
        {:error, :overloaded}
      end
    end

    @impl Storage
    def get(trace_id, opts), do: call({:get, trace_id}, opts)

    @impl Storage
    def list(opts), do: call(:list, opts)

    @impl Storage
    def delete(trace_id, opts), do: call({:delete, trace_id}, opts)

    @impl Storage
    def clear(opts), do: call(:clear, opts)

    @impl Storage
    def stats(opts) do
      case call(:stats, opts) do
        {:error, :unavailable} -> %{adapter: __MODULE__, available: false}
        stats -> stats
      end
    end

    defp call(message, opts) do
      timeout = Keyword.get(opts, :timeout, Keyword.get(opts, :call_timeout, 5_000))
      GenServer.call(__MODULE__, message, timeout)
    catch
      :exit, _reason -> {:error, :unavailable}
    end

    ## Writer process

    @impl GenServer
    def init(opts) do
      path = Keyword.fetch!(opts, :database)

      # Submissions admitted to a previous writer and never committed.
      Storage.lost_pending(__MODULE__)

      pending = :atomics.new(1, [])
      :persistent_term.put(@admission, {self(), pending})

      state = %{
        path: path,
        opts: opts,
        conn: nil,
        pending: pending,
        seq: 0,
        evicted: 0,
        write_errors: 0,
        corrupt: 0
      }

      Process.send_after(self(), :cleanup, Keyword.get(opts, :cleanup_interval, 60_000))
      {:ok, connect(state)}
    end

    @impl GenServer
    def handle_info({:put, %{"trace_id" => id} = report}, state) do
      :atomics.sub(state.pending, 1, 1)
      {:noreply, write(state, id, report)}
    end

    def handle_info(:reconnect, %{conn: nil} = state), do: {:noreply, connect(state)}
    def handle_info(:reconnect, state), do: {:noreply, state}

    def handle_info(:cleanup, state) do
      {_result, state} = run_cleanup(state)
      Process.send_after(self(), :cleanup, Keyword.get(state.opts, :cleanup_interval, 60_000))
      {:noreply, state}
    end

    def handle_info(_unexpected, state), do: {:noreply, state}

    @impl GenServer
    def handle_call(_request, _from, %{conn: nil} = state),
      do: {:reply, {:error, :unavailable}, state}

    def handle_call({:get, id}, _from, state) do
      case query(state.conn, "SELECT report FROM trace_guard_reports WHERE trace_id = ?1", [id]) do
        {:ok, [[json]]} ->
          case Jason.decode(json) do
            {:ok, report} -> {:reply, {:ok, report}, state}
            {:error, _} -> {:reply, {:error, :corrupt}, %{state | corrupt: state.corrupt + 1}}
          end

        {:ok, []} ->
          {:reply, :error, state}

        {:error, _reason} ->
          {:reply, {:error, :unavailable}, state}
      end
    end

    def handle_call(:list, _from, state) do
      case query(state.conn, "SELECT summary FROM trace_guard_reports ORDER BY seq DESC", []) do
        {:ok, rows} ->
          {summaries, corrupt} =
            Enum.reduce(rows, {[], 0}, fn [json], {acc, bad} ->
              case Jason.decode(json) do
                {:ok, summary} -> {[summary | acc], bad}
                {:error, _} -> {acc, bad + 1}
              end
            end)

          {:reply, Enum.reverse(summaries), %{state | corrupt: state.corrupt + corrupt}}

        {:error, _reason} ->
          {:reply, {:error, :unavailable}, state}
      end
    end

    def handle_call({:delete, id}, _from, state) do
      reply =
        case query(state.conn, "DELETE FROM trace_guard_reports WHERE trace_id = ?1", [id]) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :unavailable}
        end

      {:reply, reply, state}
    end

    def handle_call(:clear, _from, state) do
      reply =
        case query(state.conn, "DELETE FROM trace_guard_reports", []) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :unavailable}
        end

      {:reply, reply, state}
    end

    def handle_call(:cleanup, _from, state) do
      {result, state} = run_cleanup(state)
      {:reply, result, state}
    end

    def handle_call(:stats, _from, state) do
      retained =
        case query(state.conn, "SELECT COUNT(*) FROM trace_guard_reports", []) do
          {:ok, [[n]]} -> n
          _ -> nil
        end

      stats = %{
        adapter: __MODULE__,
        available: true,
        schema_version: @schema_version,
        retained: retained,
        max_reports: max_reports(state),
        pending: :atomics.get(state.pending, 1),
        max_pending_reports: Config.get().max_pending_reports,
        evicted: state.evicted,
        write_errors: state.write_errors,
        corrupt_reads: state.corrupt
      }

      {:reply, stats, state}
    end

    @impl GenServer
    def terminate(_reason, %{conn: conn}) when conn != nil, do: Sqlite3.close(conn)
    def terminate(_reason, _state), do: :ok

    ## Writing

    defp write(%{conn: nil} = state, id, _report) do
      Storage.dropped(id, {:sqlite, :unavailable})
      %{state | write_errors: state.write_errors + 1}
    end

    defp write(state, id, report) do
      with {:ok, report_json} <- encode(report),
           {:ok, summary_json} <- encode(Storage.summary(report)),
           {:ok, evicted} <- transaction(state, id, report_json, summary_json) do
        Storage.stored(report)
        %{state | seq: state.seq + 1, evicted: state.evicted + evicted}
      else
        {:error, :serialization_error} ->
          Storage.dropped(id, :serialization_error)
          %{state | write_errors: state.write_errors + 1}

        {:error, {:sqlite_error, message}} ->
          Storage.dropped(id, {:sqlite_error, message})
          %{state | write_errors: state.write_errors + 1}
      end
    end

    defp encode(term) do
      case Jason.encode(term) do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, :serialization_error}
      end
    end

    defp transaction(state, id, report_json, summary_json) do
      conn = state.conn
      seq = state.seq + 1

      result =
        with :ok <- exec(conn, "BEGIN IMMEDIATE"),
             {:ok, _} <-
               query(
                 conn,
                 """
                 INSERT INTO trace_guard_reports (trace_id, seq, stored_at, summary, report)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (trace_id) DO UPDATE SET
                   seq = excluded.seq, stored_at = excluded.stored_at,
                   summary = excluded.summary, report = excluded.report
                 """,
                 [id, seq, System.system_time(:millisecond), summary_json, report_json]
               ),
             {:ok, evicted} <- evict_beyond(conn, max_reports(state)),
             :ok <- exec(conn, "COMMIT") do
          {:ok, evicted}
        end

      case result do
        {:ok, evicted} ->
          {:ok, evicted}

        {:error, reason} ->
          _ = Sqlite3.execute(conn, "ROLLBACK")
          {:error, {:sqlite_error, to_message(reason)}}
      end
    end

    defp evict_beyond(conn, max) do
      sql = """
      DELETE FROM trace_guard_reports WHERE seq <=
        (SELECT seq FROM trace_guard_reports ORDER BY seq DESC LIMIT 1 OFFSET ?1)
      """

      with {:ok, _} <- query(conn, sql, [max]), do: {:ok, Sqlite3.changes(conn) |> ok_changes()}
    end

    defp ok_changes({:ok, n}), do: n
    defp ok_changes(n) when is_integer(n), do: n
    defp ok_changes(_), do: 0

    defp run_cleanup(%{conn: nil} = state), do: {{:error, :unavailable}, state}

    defp run_cleanup(state) do
      by_age =
        case Keyword.get(state.opts, :max_age) do
          nil ->
            0

          max_age ->
            cutoff = System.system_time(:millisecond) - max_age

            case query(state.conn, "DELETE FROM trace_guard_reports WHERE stored_at < ?1", [
                   cutoff
                 ]) do
              {:ok, _} -> state.conn |> Sqlite3.changes() |> ok_changes()
              {:error, _} -> 0
            end
        end

      by_count =
        case evict_beyond(state.conn, max_reports(state)) do
          {:ok, n} -> n
          {:error, _} -> 0
        end

      {{:ok, by_age + by_count}, %{state | evicted: state.evicted + by_age + by_count}}
    end

    defp max_reports(state), do: Keyword.get(state.opts, :max_reports, Config.get().max_reports)

    ## Connection

    defp connect(state) do
      case open(state.path, state.opts) do
        {:ok, conn, seq} ->
          if state.conn == nil and state.write_errors > 0,
            do: Logger.info("TraceGuard SQLite storage reconnected")

          %{state | conn: conn, seq: seq}

        {:error, reason} ->
          Logger.warning(
            "TraceGuard SQLite storage unavailable (#{to_message(reason)}); retrying every second"
          )

          Process.send_after(self(), :reconnect, 1_000)
          %{state | conn: nil}
      end
    end

    defp open(path, opts) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, conn} <- Sqlite3.open(path) do
        case setup(conn, opts) do
          {:ok, seq} ->
            {:ok, conn, seq}

          {:error, reason} ->
            Sqlite3.close(conn)
            {:error, reason}
        end
      end
    end

    defp setup(conn, opts) do
      with :ok <- Sqlite3.set_busy_timeout(conn, Keyword.get(opts, :busy_timeout, 1_000)),
           {:ok, _} <- query(conn, "PRAGMA journal_mode = WAL", []),
           :ok <- exec(conn, "PRAGMA synchronous = NORMAL"),
           {:ok, [[version]]} <- query(conn, "PRAGMA user_version", []),
           :ok <- migrate(conn, version),
           {:ok, [[seq]]} <-
             query(conn, "SELECT COALESCE(MAX(seq), 0) FROM trace_guard_reports", []) do
        {:ok, seq}
      end
    end

    defp migrate(conn, 0) do
      with :ok <- Enum.reduce_while(@schema, :ok, fn sql, :ok -> ok_or_halt(exec(conn, sql)) end) do
        exec(conn, "PRAGMA user_version = #{@schema_version}")
      end
    end

    defp migrate(_conn, @schema_version), do: :ok
    defp migrate(_conn, other), do: {:error, "unsupported schema version #{other}"}

    defp ok_or_halt(:ok), do: {:cont, :ok}
    defp ok_or_halt(error), do: {:halt, error}

    ## Statement helpers (bound parameters only)

    defp exec(conn, sql) do
      case Sqlite3.execute(conn, sql) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp query(conn, sql, params) do
      with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
        try do
          with :ok <- Sqlite3.bind(stmt, params) do
            Sqlite3.fetch_all(conn, stmt)
          end
        after
          Sqlite3.release(conn, stmt)
        end
      end
    end

    defp to_message(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
    defp to_message(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp to_message(_reason), do: "error"
  end
end
