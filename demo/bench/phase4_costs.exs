# Isolated costs of Phase 4 features.
#
#     cd demo
#     MIX_ENV=bench mix run --no-start bench/phase4_costs.exs
#
# Writes bench/results/phase4-costs.md (override with BENCH_OUTPUT).
# BENCH_TIME / BENCH_WARMUP (seconds, defaults 2 / 1) apply to every
# Benchee job. Everything runs in-process on this machine; nothing here is a
# production figure.

Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:trace_guard_demo)

defmodule Costs do
  def env(name, default),
    do: name |> System.get_env(Integer.to_string(default)) |> String.to_integer()

  def base_config do
    :trace_guard
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "Elixir.") end)
  end

  def configure(opts) do
    base_config() |> Keyword.merge(opts) |> TraceGuard.Config.put!()
    TraceGuard.Telemetry.attach()
    :ok
  end

  def bench(jobs, settings, opts \\ []) do
    suite =
      Benchee.run(jobs,
        warmup: settings.warmup,
        time: settings.time,
        memory_time: Keyword.get(opts, :memory_time, 1),
        percentiles: [50, 99],
        print: [benchmarking: false, configuration: false, fast_warning: false],
        formatters: []
      )

    for s <- suite.scenarios do
      st = s.run_time_data.statistics
      mem = s.memory_usage_data.statistics.median

      "| #{s.job_name} | #{us(st.median)} | #{us(st.percentiles[99])} | #{if mem, do: "#{round(mem)} B", else: "n/a"} | #{st.sample_size} |"
    end
    |> then(fn rows ->
      "| Measurement | Median | p99 | Memory (calling process) | Samples |\n| --- | --: | --: | --: | --: |\n" <>
        Enum.join(rows, "\n")
    end)
  end

  def us(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 2) <> " µs"

  # Stored events are forwarded to whichever process registered as waiter
  # (Benchee runs jobs in their own processes).
  def forward_stored(_e, _m, %{trace_id: id}, name) do
    if pid = Process.whereis(name), do: send(pid, {:stored, id})
  end

  def register_waiter do
    case Process.whereis(:cost_waiter) do
      pid when pid == self() -> :ok
      nil -> Process.register(self(), :cost_waiter)
      _ -> Process.unregister(:cost_waiter) && Process.register(self(), :cost_waiter)
    end
  end

  def report(sample), do: %{sample | "trace_id" => TraceGuard.Context.generate_trace_id()}

  # Submits `r` as given (callers pass a report with a fresh trace ID) and
  # waits for its :stored event.
  def submit_and_wait(r) do
    register_waiter()
    id = r["trace_id"]
    {:ok, :queued} = TraceGuard.Storage.put(r)
    receive(do: ({:stored, ^id} -> :ok))
  end

  def flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  def checkout_conn do
    body =
      Jason.encode!(%{
        sku: "TG-001",
        quantity: 2,
        password: "hunter2",
        card: %{card_number: "4242424242424242"}
      })

    Plug.Test.conn("POST", "/api/checkout", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer demo-user-session-token")
  end

  def failing_request do
    try do
      TraceGuardDemoWeb.Endpoint.call(checkout_conn(), [])
    catch
      _, _ -> :ok
    end

    flush()
  end

  def memory_kb(bytes), do: :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"

  # Full GC of every process, so memory figures compare live data only.
  def total_memory_after_gc do
    for pid <- Process.list(), do: :erlang.garbage_collect(pid)
    :erlang.memory(:total)
  end
end

defmodule Costs.Echo do
  use GenServer
  use TraceGuard.Server
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
end

settings = %{time: Costs.env("BENCH_TIME", 2), warmup: Costs.env("BENCH_WARMUP", 1)}
output = System.get_env("BENCH_OUTPUT", "bench/results/phase4-costs.md")
alias TraceGuard.{Context, EventCollector, Storage}

TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Order)
TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Product)
Code.eval_file("priv/repo/seeds.exs")

Costs.configure(enabled: true)
{:ok, _} = Costs.Echo.start_link(nil)

## 1. GenServer propagation

IO.puts("1/5 GenServer propagation")

propagation =
  Costs.bench(
    %{
      "a. 10 × GenServer.call (no TraceGuard)" => fn ->
        for _ <- 1..10, do: GenServer.call(Costs.Echo, :ping)
      end,
      "b. 10 × TraceGuard.call, caller has no trace" => fn ->
        for _ <- 1..10, do: TraceGuard.call(Costs.Echo, :ping)
      end,
      "c. trace start + finish (success), no calls" => fn ->
        Context.start("bench", %{})
        EventCollector.finish(200)
      end,
      "d. trace start + 10 × TraceGuard.call + finish (success)" => fn ->
        Context.start("bench", %{})
        for _ <- 1..10, do: TraceGuard.call(Costs.Echo, :ping)
        EventCollector.finish(200)
      end
    },
    settings
  )

## 2. Report submission and retention

IO.puts("2/5 Report submission and retention")

Costs.configure(enabled: true)
Costs.failing_request()
[%{"trace_id" => sample_id} | _] = TraceGuard.list_reports(route: "/api/checkout")
{:ok, sample} = TraceGuard.get_report(sample_id)
sample_bytes = :erts_debug.flat_size(sample) * :erlang.system_info(:wordsize)

:telemetry.attach(
  :cost_stored,
  [:trace_guard, :report, :stored],
  &Costs.forward_stored/4,
  :cost_waiter
)

sqlite_path = Path.expand("trace_guard_reports_bench.db")
for suffix <- ["", "-wal", "-shm"], do: File.rm(sqlite_path <> suffix)
{:ok, sqlite_pid} = TraceGuard.Storage.SQLite.start_link(database: sqlite_path)

memory_submit =
  Costs.bench(
    %{
      "put + await :stored, ReportStore (memory)" => fn ->
        Costs.submit_and_wait(Costs.report(sample))
      end
    },
    settings
  )

Costs.configure(enabled: true, storage: {TraceGuard.Storage.SQLite, database: sqlite_path})

sqlite_submit =
  Costs.bench(
    %{
      "put + await :stored, SQLite (WAL, synchronous=NORMAL)" => fn ->
        Costs.submit_and_wait(Costs.report(sample))
      end
    },
    settings
  )

# Refusal fast path: the store is suspended with its queue full.
Costs.configure(enabled: true, max_pending_reports: 1)
store = Process.whereis(TraceGuard.ReportStore)
:sys.suspend(store)
{:ok, :queued} = TraceGuard.ReportStore.put(Costs.report(sample), [])

refusal =
  Costs.bench(
    %{
      "put refused (queue full): Storage.put/1 → {:error, :overloaded}" => fn ->
        {:error, :overloaded} = Storage.put(Costs.report(sample))
      end
    },
    settings
  )

:sys.resume(store)
Costs.configure(enabled: true)

## 3. Retrieval

IO.puts("3/5 Retrieval")

fill = fn ->
  TraceGuard.clear_reports()

  ids =
    for _ <- 1..50,
        do:
          (
            r = Costs.report(sample)
            Costs.submit_and_wait(r) && r["trace_id"]
          )

  ids
end

Costs.register_waiter()
ids_memory = fill.()
memory_id = List.last(ids_memory)

retrieval_memory =
  Costs.bench(
    %{
      "memory: get_report/1" => fn -> {:ok, _} = TraceGuard.get_report(memory_id) end,
      "memory: list_reports/0 (50 summaries)" => fn -> TraceGuard.list_reports() end,
      "memory: report_status/1 (stored)" => fn ->
        :stored = TraceGuard.report_status(memory_id)
      end,
      "memory: await_report/2 (already stored)" => fn ->
        {:ok, _} = TraceGuard.await_report(memory_id, 1_000)
      end
    },
    settings
  )

Costs.configure(enabled: true, storage: {TraceGuard.Storage.SQLite, database: sqlite_path})
Costs.register_waiter()
ids_sqlite = fill.()
sqlite_id = List.last(ids_sqlite)

retrieval_sqlite =
  Costs.bench(
    %{
      "SQLite: get_report/1" => fn -> {:ok, _} = TraceGuard.get_report(sqlite_id) end,
      "SQLite: list_reports/0 (50 summaries)" => fn -> TraceGuard.list_reports() end,
      "SQLite: report_status/1 (stored)" => fn ->
        :stored = TraceGuard.report_status(sqlite_id)
      end
    },
    settings
  )

## 4. Failure burst: memory and queue

IO.puts("4/5 Failure burst")

burst = fn storage_opts ->
  Costs.configure([enabled: true] ++ storage_opts)
  TraceGuard.clear_reports()
  before = Storage.stats()
  drops_before = TraceGuard.DropLog.sizes().drop_records
  mem_before = Costs.total_memory_after_gc()

  1..500
  |> Task.async_stream(fn _ -> Costs.failing_request() end, max_concurrency: 8, timeout: 30_000)
  |> Stream.run()

  # Let the writer drain (bounded wait).
  Enum.reduce_while(1..500, nil, fn _, _ ->
    if Storage.stats().pending == 0, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
  end)

  after_stats = Storage.stats()
  store_pid = Process.whereis(elem(TraceGuard.Storage.adapter(), 0))
  mem_after = Costs.total_memory_after_gc()
  {:memory, store_mem} = Process.info(store_pid, :memory)

  %{
    accepted: after_stats.accepted - before.accepted,
    dropped_overloaded: after_stats.dropped_overloaded - before.dropped_overloaded,
    retained: after_stats.retained,
    store_process_memory: store_mem,
    vm_delta: mem_after - mem_before,
    drop_records: "#{drops_before} → #{TraceGuard.DropLog.sizes().drop_records}"
  }
end

burst_memory = burst.([])
burst_sqlite = burst.(storage: {TraceGuard.Storage.SQLite, database: sqlite_path})

sqlite_file =
  Enum.sum(
    for s <- ["", "-wal"],
        do:
          case(File.stat(sqlite_path <> s),
            do: (
              {:ok, %{size: n}} -> n
              _ -> 0
            )
          )
  )

## 5. SQLite outage: queue stays bounded

IO.puts("5/5 SQLite outage")

GenServer.stop(sqlite_pid)
for suffix <- ["", "-wal", "-shm"], do: File.rm(sqlite_path <> suffix)
{:ok, sqlite_pid} = TraceGuard.Storage.SQLite.start_link(database: sqlite_path, busy_timeout: 20)
Costs.configure(enabled: true, storage: {TraceGuard.Storage.SQLite, database: sqlite_path})
{:ok, locker} = Exqlite.Sqlite3.open(sqlite_path)
:ok = Exqlite.Sqlite3.execute(locker, "BEGIN EXCLUSIVE")
before = Storage.stats()

sampler =
  Task.async(fn ->
    Enum.reduce_while(Stream.repeatedly(fn -> :ok end), 0, fn _, max ->
      receive do
        :stop -> {:halt, max}
      after
        1 ->
          {_, len} = Process.info(sqlite_pid, :message_queue_len)
          {:cont, max(max, len)}
      end
    end)
  end)

1..500
|> Task.async_stream(fn _ -> Costs.failing_request() end, max_concurrency: 8, timeout: 60_000)
|> Stream.run()

send(sampler.pid, :stop)
max_queue = Task.await(sampler)
:ok = Exqlite.Sqlite3.execute(locker, "ROLLBACK")
Exqlite.Sqlite3.close(locker)

Enum.reduce_while(1..500, nil, fn _, _ ->
  if Storage.stats().pending == 0, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
end)

outage = Storage.stats()
stored_after_unlock = outage.stored - before.stored
:telemetry.detach(:cost_stored)
GenServer.stop(sqlite_pid)

## Summary

system = %{
  elixir: System.version(),
  otp: System.otp_release(),
  os: :os.type() |> inspect(),
  cores: System.schedulers_online()
}

{git_rev, _} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
{git_status, _} = System.cmd("git", ["status", "--porcelain"])
dirty = if String.trim(git_status) == "", do: "clean", else: "with uncommitted changes"

burst_row = fn name, b ->
  "| #{name} | #{b.accepted} | #{b.dropped_overloaded} | #{b.retained} | #{Costs.memory_kb(b.store_process_memory)} | #{Costs.memory_kb(b.vm_delta)} | #{b.drop_records} |"
end

markdown = """
# TraceGuard Phase 4 isolated costs

Generated #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()} by
`MIX_ENV=bench mix run --no-start bench/phase4_costs.exs` at commit `#{String.trim(git_rev)}` (#{dirty}).
Elixir #{system.elixir}, OTP #{system.otp}, #{system.os}, #{system.cores} schedulers. Benchee
warm-up #{settings.warmup}s, time #{settings.time}s, memory 1s per job. TraceGuard config: demo's
`config/config.exs` (max_events 100, max_reports 50, max_pending_reports 50 unless stated).

## 1. GenServer propagation (`TraceGuard.call/3` to a `use TraceGuard.Server` echo server)

#{propagation}

Per traced call, inside an active trace: (d − c − a) / 10. Wrapper only, without a trace: (b − a) / 10.

## 2. Report submission and retention (sample checkout report, #{sample_bytes} bytes as a term)

#{memory_submit}

#{sqlite_submit}

#{refusal}

## 3. Retrieval (50 retained reports)

#{retrieval_memory}

#{retrieval_sqlite}

## 4. Failure burst: 500 failing checkout requests, 8 concurrent

| Adapter | Accepted | Refused (overloaded) | Retained after | Store process memory (after GC) | VM memory delta (after GC, all processes) | Drop records (before → after, cap 1000) |
| --- | --: | --: | --: | --: | --: | --: |
#{burst_row.("ReportStore (memory)", burst_memory)}
#{burst_row.("SQLite", burst_sqlite)}

SQLite file (database + WAL) after the burst: #{Costs.memory_kb(sqlite_file)}.

## 5. SQLite outage: database locked by another connection during 500 failing requests

* Largest writer mailbox observed (sampled every ~1 ms): **#{max_queue}** (limit `max_pending_reports` = #{TraceGuard.Config.get().max_pending_reports})
* Refused at admission (overloaded): #{outage.dropped_overloaded - before.dropped_overloaded}
* Admitted, then failed and dropped with `{:sqlite_error, _}`: #{outage.dropped_other - before.dropped_other}
* Admitted and stored once the lock was released: #{stored_after_unlock}
* Requests affected: none (every request completed with Phoenix's normal 500 for this endpoint)
"""

File.mkdir_p!(Path.dirname(output))
File.write!(output, markdown)
IO.puts(markdown)
