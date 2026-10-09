# Allocation per TraceGuard event, isolated from HTTP and the database.
#
#     cd demo
#     MIX_ENV=bench mix run --no-start bench/event_cost.exs
#
# Emits Ecto-shaped telemetry events directly (same event name, metadata
# shape and handler as real queries). Memory is deterministic, so this is
# the most repeatable TraceGuard cost figure. Time is not reported here: at
# these durations it is dominated by measurement noise.

Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:trace_guard_demo)

:trace_guard
|> Application.get_all_env()
|> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "Elixir.") end)
|> Keyword.put(:enabled, true)
|> TraceGuard.Config.put!()

TraceGuard.Telemetry.attach()

event = [:trace_guard_demo, :repo, :query]
measurements = %{query_time: 1_000, decode_time: 100, queue_time: 50, total_time: 1_150}

metadata = %{
  type: :ecto_sql_query,
  repo: TraceGuardDemo.Repo,
  source: "products",
  query: ~s{SELECT p0."id" FROM "products" AS p0},
  result: {:ok, %{num_rows: 1}},
  params: [],
  stacktrace: nil
}

:telemetry.attach("bench-noop", [:bench, :noop], fn _, _, _, _ -> :ok end, nil)

trace = fn body ->
  fn ->
    TraceGuard.Context.start("bench", %{})
    body.()
    TraceGuard.Context.take()
  end
end

emit = fn n -> fn -> for _ <- 1..n, do: :telemetry.execute(event, measurements, metadata) end end

jobs = %{
  "a. :telemetry.execute, no-op handler (telemetry itself)" => fn ->
    :telemetry.execute([:bench, :noop], measurements, metadata)
  end,
  "b. query event outside any trace" => emit.(1),
  "c. empty trace (context start + take)" => trace.(fn -> :ok end),
  "d. trace with 100 retained query events" => trace.(emit.(100)),
  "e. trace with 100 retained + 51 dropped" => trace.(emit.(151))
}

suite =
  Benchee.run(jobs,
    warmup: 0.5,
    time: 0.5,
    memory_time: 2,
    print: [configuration: false, fast_warning: false],
    formatters: []
  )

memory = Map.new(suite.scenarios, &{&1.job_name, &1.memory_usage_data.statistics.median})

get = fn prefix ->
  Enum.find_value(memory, fn {name, bytes} -> String.starts_with?(name, prefix) && bytes end)
end

IO.puts("\nMedian bytes allocated by the calling process:\n")
for {name, bytes} <- Enum.sort(memory), do: IO.puts("  #{name}: #{round(bytes)} B")

per_retained = (get.("d.") - get.("c.")) / 100
per_dropped = (get.("e.") - get.("d.")) / 51

IO.puts("""

Derived:
  per retained event (incl. telemetry dispatch): #{round(per_retained)} B
  per dropped event  (incl. telemetry dispatch): #{round(per_dropped)} B
  telemetry dispatch alone:                      #{round(get.("a."))} B
""")
