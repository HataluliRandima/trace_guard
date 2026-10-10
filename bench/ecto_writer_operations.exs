# Operational behaviour of TraceGuard.Storage.Ecto's single writer (Phase 7):
# a database outage, recovery, a long table lock, and shutdown while blocked.
#
#     TRACE_GUARD_POSTGRES_URL=postgres://postgres@127.0.0.1:54331 \
#       MIX_ENV=test mix run bench/ecto_writer_operations.exs
#
# Uses (and drops) the test suite's throwaway database, so don't run both at
# once. Takes about four minutes, mostly the outage drain. Observations on
# one machine, not guarantees; see bench/results/phase7-ecto-operations.md.
alias TraceGuard.{Context, PostgresSupport, Storage, TestRepo}
alias TraceGuard.Storage.Ecto, as: EctoStorage

Logger.configure(level: :error)
PostgresSupport.setup!()
db = PostgresSupport.database()

TraceGuard.Config.put!(
  ecto_telemetry_prefixes: [],
  storage: {EctoStorage, repo: TestRepo},
  max_reports: 1_000,
  max_pending_reports: 50
)

{:ok, sup} =
  Supervisor.start_link([{EctoStorage, [repo: TestRepo]}], strategy: :one_for_one)

parent = self()
Process.flag(:trap_exit, true)

:telemetry.attach_many(
  :ops,
  [[:trace_guard, :report, :stored], [:trace_guard, :report, :dropped]],
  fn [_, _, kind], _, meta, _ ->
    send(
      parent,
      {:outcome, kind, meta[:trace_id], meta[:reason], System.monotonic_time(:millisecond)}
    )
  end,
  nil
)

report = fn ->
  %{
    "schema" => "traceguard.report/v1",
    "trace_id" => Context.generate_trace_id(),
    "outcome" => "exception",
    "request" => %{"method" => "GET", "route" => "/x"},
    "response" => %{"status" => 500},
    "events" => []
  }
end

collect = fn ids, timeout ->
  ids
  |> Enum.map(fn id ->
    receive do
      {:outcome, kind, ^id, reason, t} -> {kind, id, reason, t}
    after
      timeout -> {:no_outcome, id, nil, nil}
    end
  end)
end

flush = fn flush ->
  receive do
    {:outcome, _, _, _, _} -> flush.(flush)
  after
    0 -> :ok
  end
end

summarize = fn label, admitted, refused, outcomes, t0 ->
  by = Enum.frequencies_by(outcomes, fn {k, _, r, _} -> {k, r} end)
  times = for {_, _, _, t} when is_integer(t) <- outcomes, do: t - t0

  IO.puts(
    "#{label}: submitted #{admitted + refused}, admitted #{admitted}, refused at admission #{refused}"
  )

  IO.puts("  outcomes: #{inspect(by)}")
  if times != [], do: IO.puts("  last outcome after #{Enum.max(times)} ms")
  stats = TraceGuard.report_stats()

  IO.puts(
    "  report_stats: available=#{stats.available} pending=#{stats[:pending]} write_errors=#{stats[:write_errors]} last_error=#{inspect(stats[:last_error])} dropped_overloaded=#{stats[:dropped_overloaded]}"
  )
end

# Returns {admitted ids, refused count}; refusals' own :dropped events are
# flushed so only the writer's outcomes remain to be collected.
submit = fn n ->
  {ids, r} =
    Enum.reduce(1..n, {[], 0}, fn _, {ids, r} ->
      rep = report.()

      case Storage.put(rep) do
        {:ok, _} -> {[rep["trace_id"] | ids], r}
        {:error, :overloaded} -> {ids, r + 1}
      end
    end)

  ids = Enum.reverse(ids)
  admitted = MapSet.new(ids)
  # Drain refusal events now (they are emitted synchronously at admission).
  Enum.each(1..r, fn _ ->
    receive do
      {:outcome, :dropped, id, :overloaded, _} ->
        if MapSet.member?(admitted, id), do: raise("unexpected")
    after
      1_000 -> :ok
    end
  end)

  {ids, r}
end

admin = PostgresSupport.admin!()

# 1. Database unreachable: new connections refused, existing ones killed.
Postgrex.query!(admin, ~s{ALTER DATABASE "#{db}" ALLOW_CONNECTIONS false}, [])

Postgrex.query!(
  admin,
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
  [db]
)

t0 = System.monotonic_time(:millisecond)
{ids, r} = submit.(200)
outcomes = collect.(ids, 15_000)
summarize.("1. outage, 200 reports in a burst", length(ids), r, outcomes, t0)
fails = Enum.sort(for {:dropped, _, {:ecto_error, _}, t} <- outcomes, do: t)

gaps =
  fails |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [x, y] -> y - x end) |> Enum.sort()

if gaps != [],
  do:
    IO.puts(
      "  time per failed write: median #{Enum.at(gaps, div(length(gaps), 2))} ms, max #{List.last(gaps)} ms, first failure after #{hd(fails) - t0} ms, last after #{List.last(fails) - t0} ms"
    )

# 2. Recovery.
Postgrex.query!(admin, ~s{ALTER DATABASE "#{db}" ALLOW_CONNECTIONS true}, [])
t1 = System.monotonic_time(:millisecond)

recovered =
  Enum.find_value(1..200, fn _ ->
    r = report.()
    {:ok, _} = Storage.put(r)
    id = r["trace_id"]

    receive do
      {:outcome, :stored, ^id, _, t} ->
        t - t1

      {:outcome, :dropped, ^id, _, _} ->
        Process.sleep(100)
        nil
    after
      10_000 -> nil
    end
  end)

IO.puts("2. recovery: first committed write #{recovered} ms after connections were allowed again")

# 3. A long lock on the table (e.g. a migration holding ACCESS EXCLUSIVE).
TraceGuard.clear_reports()

locker =
  Task.async(fn ->
    {:ok, c} = Postgrex.start_link(PostgresSupport.repo_config() |> Keyword.delete(:pool_size))

    Postgrex.transaction(
      c,
      fn conn ->
        Postgrex.query!(conn, "LOCK TABLE trace_guard_reports IN ACCESS EXCLUSIVE MODE", [])
        send(parent, :locked)
        Process.sleep(12_000)
      end,
      timeout: 60_000
    )
  end)

receive do: (:locked -> :ok)
t2 = System.monotonic_time(:millisecond)
{ids, r} = submit.(200)
stats_during = TraceGuard.report_stats()

IO.puts(
  "  report_stats while blocked: available=#{stats_during.available} writer_running=#{stats_during[:writer_running]}"
)

outcomes = collect.(ids, 30_000)
summarize.("3. table locked for 12 s, 200 reports in a burst", length(ids), r, outcomes, t2)
Task.await(locker, 30_000)

# 4. Shutdown while the writer is stuck in a statement with a full queue.
locker =
  Task.async(fn ->
    {:ok, c} = Postgrex.start_link(PostgresSupport.repo_config() |> Keyword.delete(:pool_size))

    Postgrex.transaction(
      c,
      fn conn ->
        Postgrex.query!(conn, "LOCK TABLE trace_guard_reports IN ACCESS EXCLUSIVE MODE", [])
        send(parent, :locked)
        Process.sleep(8_000)
      end,
      timeout: 60_000
    )
  end)

receive do: (:locked -> :ok)
flush.(flush)
{ids, _} = submit.(60)
a = length(ids)
Process.sleep(200)
{us, :ok} = :timer.tc(fn -> Supervisor.stop(sup, :shutdown) end)
IO.puts("4. supervisor shutdown with the writer blocked and #{a} admitted: #{div(us, 1000)} ms")
Task.await(locker, 30_000)
{:ok, sup2} = Supervisor.start_link([{EctoStorage, [repo: TestRepo]}], strategy: :one_for_one)
Process.sleep(200)
IO.puts("   after restart: report_stats lost=#{TraceGuard.report_stats()[:lost]}")
Supervisor.stop(sup2)

:telemetry.detach(:ops)
PostgresSupport.teardown!()
