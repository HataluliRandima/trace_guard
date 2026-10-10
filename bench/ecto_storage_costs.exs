# Costs of TraceGuard.Storage.Ecto against a real PostgreSQL.
#
#     TRACE_GUARD_POSTGRES_URL=postgres://postgres@127.0.0.1:54329 \
#       MIX_ENV=test mix run bench/ecto_storage_costs.exs
#
# Plain timing with :timer.tc (no extra dependency): medians and p99 over N
# iterations after a warm-up. Single machine, local PostgreSQL over TCP; these
# are observations, not performance guarantees. Uses (and drops) the same
# throwaway database as the test suite, so don't run both at once.

alias TraceGuard.{Context, PostgresSupport, Storage, TestRepo}
alias TraceGuard.Storage.Ecto, as: EctoStorage

PostgresSupport.url() || raise "set TRACE_GUARD_POSTGRES_URL"
Logger.configure(level: :error)
PostgresSupport.setup!()

defmodule EctoCosts do
  def stats(samples_us) do
    sorted = Enum.sort(samples_us)
    n = length(sorted)

    %{
      n: n,
      median: Enum.at(sorted, div(n, 2)),
      p99: Enum.at(sorted, min(n - 1, round(n * 0.99))),
      max: List.last(sorted)
    }
  end

  def measure(n, fun) do
    for _ <- 1..max(div(n, 10), 5), do: fun.()
    for _ <- 1..n, do: elem(:timer.tc(fun), 0)
  end

  def row(label, s), do: "| #{label} | #{s.median} µs | #{s.p99} µs | #{s.max} µs | #{s.n} |"
end

sample = %{
  "schema" => "traceguard.report/v1",
  "trace_id" => "x",
  "outcome" => "exception",
  "request" => %{"method" => "POST", "route" => "/api/checkout", "request_id" => "req"},
  "response" => %{"status" => 500},
  "events" =>
    for i <- 1..20 do
      %{
        "seq" => i,
        "name" => "ecto.query",
        "process" => "request",
        "metadata" => %{"source" => "products"}
      }
    end,
  "failure" => %{
    "kind" => "error",
    "exception" => "RuntimeError",
    "message" => String.duplicate("m", 200)
  }
}

report = fn -> %{sample | "trace_id" => Context.generate_trace_id()} end

TraceGuard.Config.put!(
  ecto_telemetry_prefixes: [],
  storage: {EctoStorage, repo: TestRepo},
  max_reports: 1_000,
  max_pending_reports: 50
)

{:ok, writer} = EctoStorage.start_link(repo: TestRepo)

parent = self()

:telemetry.attach(
  :ecto_costs,
  [:trace_guard, :report, :stored],
  fn _, _, %{trace_id: id}, _ ->
    send(parent, {:stored, id})
  end,
  nil
)

submit_and_wait = fn ->
  r = report.()
  {:ok, :queued} = Storage.put(r)
  id = r["trace_id"]
  receive(do: ({:stored, ^id} -> :ok))
end

# 1. Write path. Request side: `Storage.put/1` alone (admission, pending
#    mark, send), with a queue limit high enough that nothing is refused
#    while the writer drains in the background. Then end-to-end: submit ->
#    committed (`:stored` event).
TraceGuard.Config.put!(
  ecto_telemetry_prefixes: [],
  storage: {EctoStorage, repo: TestRepo},
  max_reports: 1_000,
  max_pending_reports: 5_000
)

{admission, ids} =
  for _ <- 1..2_000, reduce: {[], []} do
    {times, ids} ->
      r = report.()
      {us, {:ok, :queued}} = :timer.tc(fn -> Storage.put(r) end)
      {[us | times], [r["trace_id"] | ids]}
  end

for id <- ids, do: receive(do: ({:stored, ^id} -> :ok))

TraceGuard.Config.put!(
  ecto_telemetry_prefixes: [],
  storage: {EctoStorage, repo: TestRepo},
  max_reports: 1_000,
  max_pending_reports: 50
)

TraceGuard.clear_reports()

write = EctoCosts.measure(500, submit_and_wait)

# 2. Reads with 1_000 rows in the table.
for _ <- 1..1_000, do: submit_and_wait.()
[%{"trace_id" => some_id} | _] = TraceGuard.list_reports()

get = EctoCosts.measure(1_000, fn -> {:ok, _} = TraceGuard.get_report(some_id) end)
status = EctoCosts.measure(1_000, fn -> :stored = TraceGuard.report_status(some_id) end)

filtered =
  EctoCosts.measure(500, fn ->
    [_ | _] = TraceGuard.list_reports(request_id: "req", route: "/api/checkout") |> Enum.take(1)
  end)

by_trace = EctoCosts.measure(1_000, fn -> [_] = TraceGuard.list_reports(trace_id: some_id) end)
full_list = EctoCosts.measure(50, fn -> 1_000 = length(TraceGuard.list_reports()) end)

# 3. Writer memory after a burst.
for pid <- Process.list(), do: :erlang.garbage_collect(pid)
{:memory, writer_mem} = Process.info(writer, :memory)
:telemetry.detach(:ecto_costs)
GenServer.stop(writer)
PostgresSupport.teardown!()

IO.puts("""
# TraceGuard.Storage.Ecto costs

Generated #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()};
Elixir #{System.version()}, OTP #{System.otp_release()}, PostgreSQL via #{PostgresSupport.url()};
report with 20 events (#{byte_size(Jason.encode!(sample))} bytes as JSON).

| Measurement | Median | p99 | Max | Samples |
| --- | --: | --: | --: | --: |
#{EctoCosts.row("Request side: `Storage.put/1` admission only", EctoCosts.stats(admission))}
#{EctoCosts.row("Submit until committed (`:stored` event)", EctoCosts.stats(write))}
#{EctoCosts.row("`get_report/1` (1,000 rows)", EctoCosts.stats(get))}
#{EctoCosts.row("`report_status/1` (stored)", EctoCosts.stats(status))}
#{EctoCosts.row("`list_reports(trace_id: ...)` (indexed, 1 row)", EctoCosts.stats(by_trace))}
#{EctoCosts.row("`list_reports(request_id:, route:)` (1,000 matching)", EctoCosts.stats(filtered))}
#{EctoCosts.row("`list_reports()` (1,000 summaries)", EctoCosts.stats(full_list))}

Writer process memory after 1,500+ writes (after GC): #{writer_mem} bytes.
""")
