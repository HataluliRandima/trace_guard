# TraceGuard request-overhead benchmark.
#
#     cd demo
#     MIX_ENV=bench mix bench.requests
#
# Compares identical requests against the same running demo application with
# TraceGuard disabled and enabled. Requests are dispatched in-process through
# TraceGuardDemoWeb.Endpoint.call/2 (Plug.Test adapter, no sockets), so the
# measurement isolates server-side request handling from network noise.
#
# Method (see docs/performance.md):
#   * Paired, alternating rounds: in every round each scenario is measured
#     disabled and enabled back to back, and the order flips every round and
#     every scenario, so slow drift of the machine does not systematically
#     favour one mode.
#   * Deltas are computed per round (enabled - disabled of the same round)
#     and reported as median and range across rounds.
#   * Report retention is separated: scenario 3 runs once with the real
#     in-memory store and once with a discarding adapter, and the store's own
#     processing is measured on its own.
#
# Environment variables (seconds unless noted):
#   BENCH_ROUNDS       paired rounds per scenario            (default 3)
#   BENCH_WARMUP       warm-up per measurement               (default 1)
#   BENCH_TIME         timing per measurement                (default 3)
#   BENCH_MEMORY_TIME  memory measurement per measurement    (default 1)
#   BENCH_CONCURRENT   set to N to add an N-process pass on read-only scenarios
#   BENCH_OUTPUT       markdown summary path (default bench/results/latest.md)

defmodule Bench do
  @endpoint TraceGuardDemoWeb.Endpoint

  def env_number(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  ## Configuration switching (outside any measurement)

  def base_config do
    :trace_guard
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "Elixir.") end)
  end

  # Same validated application config; only :enabled and, for scenario 3b,
  # :storage differ. Writing :persistent_term forces a global GC, so this is
  # done only when something changes.
  def configure(enabled?, storage \\ TraceGuard.ReportStore) do
    config = TraceGuard.Config.get()

    if config.enabled != enabled? or config.storage != storage do
      base_config()
      |> Keyword.merge(enabled: enabled?, storage: storage)
      |> TraceGuard.Config.put!()

      TraceGuard.Telemetry.attach()
    end

    TraceGuard.clear_reports()
  end

  ## Requests

  def checkout_request do
    body =
      Jason.encode!(%{
        sku: "TG-001",
        quantity: 2,
        password: "hunter2",
        card: %{card_number: "4242424242424242", cvc: "123"}
      })

    req("POST", "/api/checkout", body, [
      {"content-type", "application/json"},
      {"authorization", "Bearer demo-user-session-token"},
      {"x-api-key", "demo-client-key-123"}
    ])
  end

  # {name, request, storage used when enabled, read_only?}
  def scenarios do
    [
      {"1. GET /api/health (success, no DB)", req("GET", "/api/health"), TraceGuard.ReportStore,
       true},
      {"2. GET /api/catalog (success, 4 Ecto queries)", req("GET", "/api/catalog"),
       TraceGuard.ReportStore, true},
      {"3a. POST /api/checkout (exception; report built and stored)", checkout_request(),
       TraceGuard.ReportStore, false},
      {"3b. POST /api/checkout (exception; report built, discarded)", checkout_request(),
       Bench.DiscardStorage, false},
      {"4. GET /api/inventory/audit (success, 151 queries > max_events)",
       req("GET", "/api/inventory/audit"), TraceGuard.ReportStore, true},
      {"5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks)",
       req("GET", "/api/catalog/parallel"), TraceGuard.ReportStore, true},
      {"6. POST /api/quote (success, 1 traced GenServer call with 1 query)",
       req("POST", "/api/quote", Jason.encode!(%{sku: "TG-001", qty: 2}), [
         {"content-type", "application/json"}
       ]), TraceGuard.ReportStore, true}
    ]
  end

  defp req(method, path, body \\ nil, headers \\ []) do
    %{method: method, path: path, body: body, headers: headers}
  end

  def request(%{method: method, path: path, body: body, headers: headers}) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path, body), fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    status =
      try do
        @endpoint.call(conn, @endpoint.init([])).status
      catch
        # Phoenix re-raises after rendering the 500, exactly as under Bandit.
        _kind, _reason -> 500
      end

    flush_mailbox()
    status
  end

  # The Plug.Test adapter messages the caller on every response; drop them
  # so the benchmarking process's mailbox does not grow during the run.
  def flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  ## Measurement

  # One Benchee run for one scenario in one mode. Returns plain numbers.
  def measure({_name, request, storage, _read_only}, mode, settings, parallel) do
    configure(mode == :on, storage)

    suite =
      Benchee.run(%{"run" => fn -> request(request) end},
        warmup: settings.warmup,
        time: settings.time,
        memory_time: if(parallel == 1, do: settings.memory_time, else: 0),
        parallel: parallel,
        percentiles: [50, 99],
        print: [benchmarking: false, configuration: false, fast_warning: false],
        formatters: []
      )

    [scenario] = suite.scenarios
    stats = scenario.run_time_data.statistics

    %{
      median: stats.median,
      p99: stats.percentiles[99],
      throughput: parallel * 1.0e9 / stats.average,
      samples: stats.sample_size,
      memory: scenario.memory_usage_data.statistics.median,
      system: suite.system
    }
  end

  # Paired, alternating rounds. Returns %{scenario_name => [{off, on}, ...]}.
  def run_rounds(scenarios, settings, parallel) do
    for {scenario, s_index} <- Enum.with_index(scenarios), into: %{} do
      {name, _, _, _} = scenario

      rounds =
        for round <- 1..settings.rounds do
          order = if rem(round + s_index, 2) == 0, do: [:off, :on], else: [:on, :off]
          IO.puts("  #{name} | round #{round} | order #{inspect(order)}")
          results = Map.new(order, &{&1, measure(scenario, &1, settings, parallel)})
          {results.off, results.on}
        end

      {name, rounds}
    end
  end

  ## Statistics and formatting

  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  def range(values), do: {Enum.min(values), Enum.max(values)}

  def us(ns) when is_number(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 1) <> " µs"
  def us(_), do: "n/a"

  def kb(bytes) when is_number(bytes),
    do: :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"

  def kb(_), do: "n/a"

  def signed(value, fun), do: if(value >= 0, do: "+" <> fun.(value), else: "−" <> fun.(-value))

  def range_cell({min, max}, fun), do: "#{fun.(min)} – #{fun.(max)}"

  def results_table(results, scenarios, with_memory?) do
    rows =
      for {name, _, _, _} <- scenarios, Map.has_key?(results, name) do
        rounds = results[name]
        offs = Enum.map(rounds, &elem(&1, 0))
        ons = Enum.map(rounds, &elem(&1, 1))
        deltas = Enum.map(rounds, fn {off, on} -> on.median - off.median end)
        p99_deltas = Enum.map(rounds, fn {off, on} -> on.p99 - off.p99 end)

        tp =
          Enum.map(rounds, fn {off, on} ->
            (on.throughput - off.throughput) / off.throughput * 100
          end)

        memory =
          if with_memory? do
            {lo, hi} = rounds |> Enum.map(fn {off, on} -> on.memory - off.memory end) |> range()

            [
              if(lo == hi,
                do: signed(lo, &kb/1),
                else: "#{signed(lo, &kb/1)} … #{signed(hi, &kb/1)}"
              )
            ]
          else
            []
          end

        cells =
          [
            name,
            us(median(Enum.map(offs, & &1.median))),
            range_cell(range(Enum.map(offs, & &1.median)), &us/1),
            us(median(Enum.map(ons, & &1.median))),
            signed(median(deltas), &us/1),
            range_cell(range(deltas), fn v -> signed(v, &us/1) end),
            signed(median(p99_deltas), &us/1),
            signed(median(tp), &:erlang.float_to_binary(&1, decimals: 1)) <> "%"
          ] ++ memory

        "| " <> Enum.join(cells, " | ") <> " |"
      end

    memory_header = if with_memory?, do: " Δ memory |", else: ""
    memory_align = if with_memory?, do: " --: |", else: ""

    """
    | Scenario | Off median | Off range (drift) | On median | Δ median | Δ range | Δ p99 | Δ throughput |#{memory_header}
    | --- | --: | --: | --: | --: | --: | --: | --: |#{memory_align}
    #{Enum.join(rows, "\n")}
    """
  end

  def raw_table(results, scenarios) do
    rows =
      for {name, _, _, _} <- scenarios,
          Map.has_key?(results, name),
          {{off, on}, round} <- Enum.with_index(results[name], 1) do
        "| #{name} | #{round} | #{us(off.median)} | #{us(on.median)} | #{us(off.p99)} | " <>
          "#{us(on.p99)} | #{kb(off.memory)} | #{kb(on.memory)} | #{off.samples} / #{on.samples} |"
      end

    """
    | Scenario | Round | Off median | On median | Off p99 | On p99 | Off memory | On memory | Samples off / on |
    | --- | --: | --: | --: | --: | --: | --: | --: | --: |
    #{Enum.join(rows, "\n")}
    """
  end

  # Benchee runs each benchmark function in its own process, so stored
  # events go to whichever process registered itself as the waiter.
  def forward_stored(_event, _measurements, %{trace_id: id}, name) do
    if pid = Process.whereis(name), do: send(pid, {:stored, id})
  end

  def register_waiter(name) do
    case Process.whereis(name) do
      pid when pid == self() ->
        true

      nil ->
        Process.register(self(), name)

      _other ->
        Process.unregister(name)
        Process.register(self(), name)
    end
  end
end

defmodule Bench.DiscardStorage do
  @moduledoc false
  # Accepts and immediately forgets reports: isolates building a report from
  # retaining it.
  @behaviour TraceGuard.Storage
  @impl true
  def put(_report, _opts), do: {:ok, :stored}
  @impl true
  def get(_id, _opts), do: :error
  @impl true
  def list(_opts), do: []
  @impl true
  def delete(_id, _opts), do: :ok
  @impl true
  def clear(_opts), do: :ok
  @impl true
  def stats(_opts), do: %{adapter: __MODULE__}
end

settings = %{
  rounds: Bench.env_number("BENCH_ROUNDS", 3),
  warmup: Bench.env_number("BENCH_WARMUP", 1),
  time: Bench.env_number("BENCH_TIME", 3),
  memory_time: Bench.env_number("BENCH_MEMORY_TIME", 1)
}

concurrent = Bench.env_number("BENCH_CONCURRENT", 0)
output = System.get_env("BENCH_OUTPUT", "bench/results/latest.md")

## 1. One-time costs (separated from steady state)

# `mix run --no-start` starts :logger before config/bench.exs applies.
Logger.configure(level: Application.get_env(:logger, :level, :error))

{tg_start_us, {:ok, _}} = :timer.tc(fn -> Application.ensure_all_started(:trace_guard) end)

{tg_reload_us, _} =
  :timer.tc(fn -> TraceGuard.Config.load!() && TraceGuard.Telemetry.attach() end)

{app_start_us, {:ok, _}} =
  :timer.tc(fn -> Application.ensure_all_started(:trace_guard_demo) end)

# Deterministic fixture: the same two products every run.
TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Order)
TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Product)
Code.eval_file("priv/repo/seeds.exs")

IO.puts("Measuring one-time costs (first request per scenario)...")

cold =
  for {name, request, storage, _} <- Bench.scenarios() do
    Bench.configure(true, storage)
    {us, status} = :timer.tc(fn -> Bench.request(request) end)
    {name, us, status}
  end

## 2. Sanity checks: same responses in both modes; reports only when enabled.

IO.puts("Sanity checks...")
expected = [200, 200, 500, 500, 200, 200, 200]

for enabled? <- [false, true] do
  statuses =
    Enum.map(Bench.scenarios(), fn {_, request, storage, _} ->
      Bench.configure(enabled?, storage)
      Bench.request(request)
    end)

  statuses == expected ||
    raise "unexpected statuses #{inspect(statuses)} (enabled: #{enabled?})"
end

Bench.configure(false)
Bench.request(Bench.checkout_request())
[] = TraceGuard.list_reports()

stored_handler = {:bench, :stored}

:telemetry.attach(
  stored_handler,
  [:trace_guard, :report, :stored],
  &Bench.forward_stored/4,
  :bench_report_waiter
)

Bench.register_waiter(:bench_report_waiter)
Bench.configure(true)
Bench.request(Bench.checkout_request())
sample_id = receive(do: ({:stored, id} -> id))
{:ok, sample_report} = TraceGuard.get_report(sample_id)

## 3. Report retention, measured on its own (store process work)

IO.puts("Measuring report retention...")

retention =
  Benchee.run(
    %{
      "submit + retain one report" => fn ->
        Bench.register_waiter(:bench_report_waiter)
        report = %{sample_report | "trace_id" => TraceGuard.Context.generate_trace_id()}
        id = report["trace_id"]
        {:ok, :queued} = TraceGuard.Storage.put(report)
        receive(do: ({:stored, ^id} -> :ok))
      end
    },
    warmup: settings.warmup,
    time: settings.time,
    percentiles: [50, 99],
    print: [benchmarking: false, configuration: false, fast_warning: false],
    formatters: []
  )

:telemetry.detach(stored_handler)
[retention_scenario] = retention.scenarios
retention_stats = retention_scenario.run_time_data.statistics
report_bytes = :erts_debug.flat_size(sample_report) * :erlang.system_info(:wordsize)
report_json = byte_size(Jason.encode!(sample_report))

## 4. Steady state: paired alternating rounds

IO.puts("\nSequential rounds:")
sequential = Bench.run_rounds(Bench.scenarios(), settings, 1)

concurrent_results =
  if concurrent > 1 do
    read_only = Enum.filter(Bench.scenarios(), &elem(&1, 3))
    IO.puts("\nConcurrent rounds (#{concurrent} processes):")
    Bench.run_rounds(read_only, settings, concurrent)
  end

## 5. Markdown summary

system = sequential |> Map.values() |> hd() |> hd() |> elem(0) |> Map.fetch!(:system)

{git_rev, _} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
{git_status, _} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
dirty = if String.trim(git_status) == "", do: "clean", else: "with uncommitted changes"

on_median = fn name ->
  sequential[name] |> Enum.map(fn {_, on} -> on.median end) |> Bench.median()
end

submit_delta =
  on_median.("3a. POST /api/checkout (exception; report built and stored)") -
    on_median.("3b. POST /api/checkout (exception; report built, discarded)")

concurrent_section =
  if concurrent_results do
    read_only = Enum.filter(Bench.scenarios(), &elem(&1, 3))

    "## Steady state, #{concurrent} concurrent processes (read-only scenarios)\n\n" <>
      Bench.results_table(concurrent_results, read_only, false)
  else
    "Concurrent pass not run (set `BENCH_CONCURRENT=4` to add it)."
  end

markdown = """
# TraceGuard request-overhead benchmark

Generated #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()} by
`MIX_ENV=bench mix bench.requests` at commit `#{String.trim(git_rev)}` (#{dirty}).

## Environment and settings

* Elixir #{system.elixir}, Erlang/OTP #{system.erlang}, JIT #{system.jit_enabled?}
* #{system.os}, #{system.num_cores} cores, #{system.cpu_speed}, #{system.available_memory}
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* #{settings.rounds} paired rounds per scenario; per measurement: warm-up #{settings.warmup}s,
  timing #{settings.time}s, memory #{settings.memory_time}s; the off/on order alternates per
  round and scenario
* TraceGuard config (both modes, except `enabled` and, for 3b, `storage`):
  `#{inspect(Bench.base_config(), limit: :infinity)}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: #{tg_start_us} µs
* Re-running config validation + telemetry attach: #{tg_reload_us} µs
* `Application.ensure_all_started(:trace_guard_demo)`: #{app_start_us} µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
#{Enum.map_join(cold, "\n", fn {name, us, status} -> "  * #{name}: #{us} µs (status #{status})" end)}

## Steady state, sequential

"Off range (drift)" is the spread of the disabled medians across rounds, i.e.
how much the machine itself moved. Δ values are enabled − disabled within the
same round; the table shows their median and range across rounds. Memory is
allocated **by the request process** (Benchee `memory_time`); a report sent
to the store is copied into the store's heap and is not included.

#{Bench.results_table(sequential, Bench.scenarios(), true)}

Report submission cost in the request process (3a − 3b, enabled medians):
#{Bench.signed(submit_delta, &Bench.us/1)}.

## Report retention (store process), measured separately

* Submit one checkout report and wait for its `[:trace_guard, :report, :stored]` event:
  median #{Bench.us(retention_stats.median)}, p99 #{Bench.us(retention_stats.percentiles[99])}
  (#{retention_stats.sample_size} samples).
* Size of that report: #{report_bytes} bytes as an Erlang term (flat size), #{report_json} bytes
  as JSON. At that size, the default bounds (`max_reports: 50` retained plus
  `max_pending_reports: 50` queued) hold at most about
  #{Float.round(report_bytes * 100 / 1_048_576, 1)} MB of reports.

#{concurrent_section}

## Raw per-round measurements (sequential)

#{Bench.raw_table(sequential, Bench.scenarios())}
"""

File.mkdir_p!(Path.dirname(output))
File.write!(output, markdown)
IO.puts("\nSummary written to #{output}\n")
IO.puts(markdown)
