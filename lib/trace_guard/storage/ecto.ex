if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule TraceGuard.Storage.Ecto do
    @moduledoc """
    **Experimental in 0.1.0-rc.2** (the Ecto/PostgreSQL adapter): the API may
    change before 1.0.

    Stores reports in your application's **existing PostgreSQL database
    through your existing Ecto Repo**. No second Repo, connection pool or
    database is created.

        # mix.exs: ecto_sql and postgrex come from your application
        # config/config.exs
        config :trace_guard, storage: {TraceGuard.Storage.Ecto, repo: MyApp.Repo}

    The table is created by **your** migration (see
    `TraceGuard.Storage.Ecto.Migration` and `mix trace_guard.gen.ecto_migration`).
    Nothing is created or migrated at startup.

    ## Options

      * `:repo` (required): your `Ecto.Repo`, using `Ecto.Adapters.Postgres`.
      * `:prefix`: the PostgreSQL schema of the table, if not the default.
      * `:max_reports`: rows kept (default: the `:max_reports` config). The
        oldest are deleted in the same transaction as each insert.
      * `:max_age`: if set, rows older than this many milliseconds (database
        clock) are deleted by cleanup.
      * `:cleanup_interval`: periodic cleanup in ms (default 60_000).
      * `:write_timeout`: per-statement timeout for the writer, in ms
        (default 5_000).
      * `:call_timeout`: default timeout for reads, in ms (default 5_000).

    Unknown or invalid options raise `ArgumentError` when the adapter starts.

    ## How it uses your Repo

      * **Writes** happen only in this adapter's writer process, which
        TraceGuard starts at boot, before your Repo. The writer never queries
        in `init/1`, so a missing table or an unreachable database doesn't
        stop it from starting. It uses at most **one** connection from your
        pool at a time.
      * **Reads** (`get_report/1`, `list_reports/1`, `report_status/1`, ...)
        run in the calling process, through your pool.
      * Every statement passes `log: false` and `telemetry_event: nil`, so
        TraceGuard's own queries don't appear in your Ecto logs or telemetry,
        and are never traced by TraceGuard itself.
      * With `Ecto.Adapters.SQL.Sandbox` in your tests, use shared mode (or
        allow the writer, `Process.whereis(TraceGuard.Storage.Ecto)`), as for
        any other process that queries.

    ## Request path, queue and failures

    `put/2` runs in the request process and only does admission (an
    `:atomics` increment against `:max_pending_reports`) and a `send/2` to
    the writer. That is the same bounded-queue contract as
    `TraceGuard.ReportStore`: **no database work happens in the request**.
    The writer's mailbox never holds more than `:max_pending_reports`
    reports.

    Each report is one transaction: upsert by `trace_id`, then delete rows
    beyond `:max_reports`. It is announced as stored only after the commit.
    On any error, the report is dropped with an explicit reason, never
    retried, and the writer carries on:

      * `{:ecto_error, code}`, where `code` is the PostgreSQL error code as an
        atom (for example `:undefined_table`, `:read_only_sql_transaction`),
        or `:connection` (database unreachable), `:repo_not_started`,
        `:timeout`, `:serialization`. Server error *messages* are never
        stored or logged: they can quote row values.

    The writer logs one warning when writes start failing and one notice when
    they succeed again (error code only), never per report.

    ## Deleted data

    Deletion is logical (`DELETE`). PostgreSQL keeps old row versions until
    `VACUUM` reclaims them, and deleted data can remain in the WAL, in
    replicas, in backups and in PITR archives for as long as those are
    retained. TraceGuard can't erase it from any of those. Use your
    database's own retention controls.
    """

    @behaviour TraceGuard.Storage

    use GenServer

    import Ecto.Query

    require Logger

    alias TraceGuard.{Config, Storage}

    @admission {__MODULE__, :admission}
    # The writer answers stats from memory. No answer within this time means
    # it is inside a slow statement (a lock, an unreachable database).
    @writer_stats_timeout 1_000
    @table "trace_guard_reports"
    @schema "traceguard.report/v1"
    @options [
      :repo,
      :prefix,
      :max_reports,
      :max_age,
      :cleanup_interval,
      :write_timeout,
      :call_timeout
    ]

    # Summary field -> column, for list_matching/2. Fixed atoms only.
    @columns %{
      "trace_id" => :trace_id,
      "incoming_id" => :incoming_id,
      "request_id" => :request_id,
      "route" => :route,
      "method" => :method,
      "status" => :status,
      "outcome" => :outcome,
      "kind" => :kind,
      "exception" => :exception
    }

    @replace_columns Map.values(@columns) -- [:trace_id]
    @replace_columns @replace_columns ++ [:summary, :report, :inserted_at]

    @doc false
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @doc """
    Applies `:max_age` and `:max_reports` now, in the writer. Returns
    `{:ok, deleted_rows}` or `{:error, reason}`.
    """
    @spec cleanup(timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
    def cleanup(timeout \\ 15_000) do
      GenServer.call(__MODULE__, :cleanup, timeout)
    catch
      :exit, _ -> {:error, :unavailable}
    end

    ## TraceGuard.Storage callbacks

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
    def get(trace_id, opts) do
      read(opts, fn repo, query_opts ->
        query =
          from(r in @table,
            where: r.trace_id == ^trace_id,
            select: r.report
          )

        case repo.one(prefixed(query, opts), query_opts) do
          nil -> :error
          report -> if compatible?(report, trace_id), do: {:ok, report}, else: {:error, :corrupt}
        end
      end)
    end

    # A stored report must be a map with its own trace ID and, if it names a
    # schema, the one this version writes.
    defp compatible?(%{"trace_id" => trace_id} = report, trace_id),
      do: Map.get(report, "schema", @schema) == @schema

    defp compatible?(_report, _trace_id), do: false

    @impl Storage
    def list(opts), do: list_matching([], opts)

    @impl Storage
    def list_matching(criteria, opts) do
      read(opts, fn repo, query_opts ->
        query =
          Enum.reduce(criteria, from(r in @table, order_by: [desc: r.id], select: r.summary), fn
            {field, value}, query ->
              case @columns do
                %{^field => column} when is_nil(value) ->
                  where(query, [r], is_nil(field(r, ^column)))

                %{^field => column} ->
                  where(query, [r], field(r, ^column) == ^value)

                # Unknown field: no row can match exactly, and the facade
                # re-filters anyway.
                _ ->
                  where(query, false)
              end
          end)

        query
        |> prefixed(opts)
        |> repo.all(query_opts)
        |> Enum.filter(&match?(%{"trace_id" => id} when is_binary(id), &1))
      end)
    end

    @impl Storage
    def delete(trace_id, opts) do
      read(opts, fn repo, query_opts ->
        repo.delete_all(
          prefixed(from(r in @table, where: r.trace_id == ^trace_id), opts),
          query_opts
        )

        :ok
      end)
    end

    @impl Storage
    def clear(opts) do
      read(opts, fn repo, query_opts ->
        repo.delete_all(prefixed(from(r in @table), opts), query_opts)
        :ok
      end)
    end

    @impl Storage
    def stats(opts) do
      writer =
        try do
          GenServer.call(__MODULE__, :writer_stats, @writer_stats_timeout)
        catch
          :exit, _ -> busy_or_down()
        end

      retained =
        case read(opts, fn repo, query_opts ->
               repo.aggregate(prefixed(from(r in @table), opts), :count, query_opts)
             end) do
          {:error, _} -> nil
          n -> n
        end

      Map.merge(writer, %{
        adapter: __MODULE__,
        available: is_integer(retained),
        retained: retained,
        max_pending_reports: Config.get().max_pending_reports
      })
    end

    # A busy writer is still running: say so, with the queue length from the
    # admission counter, rather than reporting it as down.
    defp busy_or_down do
      with {pid, pending} <- :persistent_term.get(@admission, nil),
           true <- Process.alive?(pid) do
        %{writer_running: true, writer_busy: true, pending: :atomics.get(pending, 1)}
      else
        _ -> %{writer_running: false}
      end
    end

    # Reads run in the caller, through the application's pool. Any failure
    # (repo not started, database down, table missing) is :unavailable.
    defp read(opts, fun) do
      repo = Keyword.fetch!(opts, :repo)
      timeout = Keyword.get(opts, :timeout, Keyword.get(opts, :call_timeout, 5_000))
      fun.(repo, query_opts(timeout))
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end

    defp query_opts(timeout), do: [timeout: timeout, log: false, telemetry_event: nil]

    defp prefixed(query, opts) do
      case Keyword.get(opts, :prefix) do
        nil -> query
        prefix -> put_query_prefix(query, prefix)
      end
    end

    ## Writer process

    @impl GenServer
    def init(opts) do
      validate_options!(opts)

      # Submissions admitted to a previous writer and never committed.
      Storage.lost_pending(__MODULE__)

      pending = :atomics.new(1, [])
      :persistent_term.put(@admission, {self(), pending})
      Process.send_after(self(), :cleanup, Keyword.get(opts, :cleanup_interval, 60_000))

      {:ok,
       %{
         opts: opts,
         pending: pending,
         written: 0,
         write_errors: 0,
         evicted: 0,
         last_error: nil,
         failing?: false
       }}
    end

    @impl GenServer
    def handle_info({:put, %{"trace_id" => id} = report}, state) do
      :atomics.sub(state.pending, 1, 1)

      case write(report, state.opts) do
        {:ok, evicted} ->
          Storage.stored(report)

          {:noreply,
           recovered(%{state | written: state.written + 1, evicted: state.evicted + evicted})}

        {:error, reason} ->
          Storage.dropped(id, {:ecto_error, reason})
          {:noreply, failed(state, reason)}
      end
    end

    def handle_info(:cleanup, state) do
      {_result, state} = run_cleanup(state)
      Process.send_after(self(), :cleanup, Keyword.get(state.opts, :cleanup_interval, 60_000))
      {:noreply, state}
    end

    def handle_info(_unexpected, state), do: {:noreply, state}

    @impl GenServer
    def handle_call(:cleanup, _from, state) do
      {result, state} = run_cleanup(state)
      {:reply, result, state}
    end

    def handle_call(:writer_stats, _from, state) do
      {:reply,
       %{
         writer_running: true,
         writer_busy: false,
         pending: :atomics.get(state.pending, 1),
         written: state.written,
         write_errors: state.write_errors,
         evicted: state.evicted,
         last_error: state.last_error,
         max_reports: max_reports(state.opts)
       }, state}
    end

    defp write(report, opts) do
      repo = Keyword.fetch!(opts, :repo)
      query_opts = query_opts(Keyword.get(opts, :write_timeout, 5_000))
      summary = Storage.summary(report)

      row =
        Map.new(@columns, fn {field, column} -> {column, summary[field]} end)
        |> Map.merge(%{summary: summary, report: report})

      guarded(fn ->
        repo.transaction(
          fn ->
            repo.insert_all(
              @table,
              [row],
              query_opts ++
                [
                  # Schemaless insert_all needs an explicit list. A resubmitted
                  # trace replaces its row (and counts as new for :max_age).
                  on_conflict: {:replace, @replace_columns},
                  conflict_target: [:trace_id],
                  prefix: Keyword.get(opts, :prefix)
                ]
            )

            evict_beyond(repo, opts, max_reports(opts), query_opts)
          end,
          query_opts
        )
      end)
    end

    defp evict_beyond(repo, opts, max, query_opts) do
      cutoff =
        from(r in @table, order_by: [desc: r.id], offset: ^max, limit: 1, select: r.id)
        |> prefixed(opts)
        |> repo.one(query_opts)

      case cutoff do
        nil ->
          0

        id ->
          {n, _} =
            repo.delete_all(prefixed(from(r in @table, where: r.id <= ^id), opts), query_opts)

          n
      end
    end

    defp run_cleanup(state) do
      opts = state.opts
      repo = Keyword.fetch!(opts, :repo)
      query_opts = query_opts(Keyword.get(opts, :write_timeout, 5_000))

      result =
        guarded(fn ->
          repo.transaction(
            fn ->
              by_age =
                case Keyword.get(opts, :max_age) do
                  nil ->
                    0

                  max_age ->
                    query =
                      from(r in @table,
                        where:
                          r.inserted_at <
                            fragment("now() - (? * interval '1 millisecond')", ^max_age)
                      )

                    {n, _} = repo.delete_all(prefixed(query, opts), query_opts)
                    n
                end

              by_age + evict_beyond(repo, opts, max_reports(opts), query_opts)
            end,
            query_opts
          )
        end)

      case result do
        {:ok, n} -> {{:ok, n}, %{state | evicted: state.evicted + n}}
        {:error, reason} -> {{:error, {:ecto_error, reason}}, failed(state, reason)}
      end
    end

    # Runs database work; never raises or exits. Errors are reduced to a
    # code: PostgreSQL error messages can quote row values.
    defp guarded(fun) do
      case fun.() do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason_code(reason)}
      end
    rescue
      e -> {:error, reason_code(e)}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, _ -> {:error, :connection}
    end

    defp reason_code(%{__struct__: Postgrex.Error, postgres: %{code: code}}) when is_atom(code),
      do: code

    defp reason_code(%DBConnection.ConnectionError{}), do: :connection
    defp reason_code(%Jason.EncodeError{}), do: :serialization
    defp reason_code(%Protocol.UndefinedError{}), do: :serialization

    defp reason_code(%RuntimeError{message: "could not lookup Ecto repo" <> _}),
      do: :repo_not_started

    # Any other exception: its module (an existing atom; no atoms are created).
    defp reason_code(%{__exception__: true, __struct__: module}), do: module

    defp reason_code(_), do: :other

    defp failed(state, reason) do
      unless state.failing?,
        do: Logger.warning("TraceGuard Ecto storage: writes failing (#{inspect(reason)})")

      %{state | write_errors: state.write_errors + 1, last_error: reason, failing?: true}
    end

    defp recovered(%{failing?: true} = state) do
      Logger.info("TraceGuard Ecto storage: writes succeeding again")
      %{state | failing?: false}
    end

    defp recovered(state), do: state

    defp max_reports(opts), do: Keyword.get(opts, :max_reports, Config.get().max_reports)

    defp validate_options!(opts) do
      case Keyword.keys(opts) -- @options do
        [] ->
          :ok

        unknown ->
          raise ArgumentError, "unknown #{inspect(__MODULE__)} options: #{inspect(unknown)}"
      end

      repo = Keyword.get(opts, :repo)

      unless is_atom(repo) and not is_nil(repo) and Code.ensure_loaded?(repo) and
               function_exported?(repo, :__adapter__, 0) do
        raise ArgumentError, "#{inspect(__MODULE__)} requires :repo, an Ecto.Repo module"
      end

      unless repo.__adapter__() == Ecto.Adapters.Postgres do
        raise ArgumentError,
              "#{inspect(__MODULE__)} supports PostgreSQL repos only " <>
                "(#{inspect(repo)} uses #{inspect(repo.__adapter__())})"
      end

      for key <- [:max_reports, :cleanup_interval, :write_timeout, :call_timeout],
          Keyword.has_key?(opts, key),
          not (is_integer(opts[key]) and opts[key] > 0),
          do:
            raise(
              ArgumentError,
              "#{inspect(__MODULE__)} option #{inspect(key)} must be a positive integer"
            )

      if Keyword.has_key?(opts, :max_age) and
           not (is_integer(opts[:max_age]) and opts[:max_age] >= 0),
         do:
           raise(
             ArgumentError,
             "#{inspect(__MODULE__)} option :max_age must be a non-negative integer"
           )

      if Keyword.has_key?(opts, :prefix) and not is_binary(opts[:prefix]),
        do: raise(ArgumentError, "#{inspect(__MODULE__)} option :prefix must be a string")

      :ok
    end
  end
end
