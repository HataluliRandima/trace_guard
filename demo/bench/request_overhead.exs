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
# Environment variables (seconds unless noted):
#   BENCH_WARMUP       warm-up per scenario            (default 2)
#   BENCH_TIME         measurement time per scenario   (default 5)
#   BENCH_MEMORY_TIME  memory measurement per scenario (default 1)
#   BENCH_PARALLEL     processes for the throughput run (default 4)
#   BENCH_OUTPUT       markdown summary path (default bench/results/latest.md)

defmodule Bench do
  @endpoint TraceGuardDemoWeb.Endpoint

  def env_number(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  ## TraceGuard switching

  # Same validated application config, only :enabled differs. Benchee runs
  # before_scenario hooks in every parallel process, so only the first one to
  # arrive rewrites the config (a :persistent_term write forces a global GC).
  def configure(enabled?) do
    if TraceGuard.Config.get().enabled != enabled?, do: put_config(enabled?)
    TraceGuard.clear_reports()
  end

  defp put_config(enabled?) do
    :trace_guard
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "Elixir.") end)
    |> Keyword.put(:enabled, enabled?)
    |> TraceGuard.Config.put!()

    TraceGuard.Telemetry.attach()
  end

  ## Requests

  def scenarios do
    checkout_body =
      Jason.encode!(%{
        sku: "TG-001",
        quantity: 2,
        password: "hunter2",
        card: %{card_number: "4242424242424242", cvc: "123"}
      })

    [
      {"1. GET /api/health (success, no DB)", req("GET", "/api/health")},
      {"2. GET /api/catalog (success, 4 Ecto queries)", req("GET", "/api/catalog")},
      {"3. POST /api/checkout (exception, 5 queries, report built)",
       req("POST", "/api/checkout", checkout_body, [
         {"content-type", "application/json"},
         {"authorization", "Bearer demo-user-session-token"},
         {"x-api-key", "demo-client-key-123"}
       ])},
      {"4. GET /api/inventory/audit (success, 151 queries > max_events)",
       req("GET", "/api/inventory/audit")},
      {"5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks)",
       req("GET", "/api/catalog/parallel")}
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
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  ## Reporting

  def summary(suite, title, parallel) do
    by_input = Enum.group_by(suite.scenarios, & &1.input_name)

    rows =
      for {input, _} <- scenarios(), Map.has_key?(by_input, input) do
        off = Enum.find(by_input[input], &(&1.job_name == "TraceGuard disabled"))
        on = Enum.find(by_input[input], &(&1.job_name == "TraceGuard enabled"))
        row(input, off, on, parallel)
      end

    """
    ### #{title}

    | Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
    | --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
    #{Enum.join(rows, "\n")}
    """
  end

  defp row(input, off, on, parallel) do
    [mo, mn] = Enum.map([off, on], & &1.run_time_data.statistics.median)
    [po, pn] = Enum.map([off, on], & &1.run_time_data.statistics.percentiles[99])
    [to, tn] = Enum.map([off, on], &(parallel * 1.0e9 / &1.run_time_data.statistics.average))
    [so, sn] = Enum.map([off, on], & &1.run_time_data.statistics.sample_size)
    [bo, bn] = Enum.map([off, on], & &1.memory_usage_data.statistics.median)

    cells = [
      input,
      us(mo),
      us(mn),
      "#{us(mn - mo)} (#{pct(mn, mo)})",
      us(po),
      us(pn),
      rate(to),
      rate(tn),
      pct(tn, to),
      kb(bo),
      kb(bn),
      if(bo && bn, do: "#{kb(bn - bo)} (#{pct(bn, bo)})", else: "n/a"),
      "#{so} / #{sn}"
    ]

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp us(ns) when is_number(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 1) <> " µs"
  defp us(_), do: "n/a"

  defp kb(nil), do: "n/a"
  defp kb(bytes), do: :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"

  defp rate(per_s), do: "#{round(per_s)}/s"

  defp pct(_new, old) when old in [nil, 0, +0.0], do: "n/a"
  defp pct(nil, _old), do: "n/a"

  defp pct(new, old) do
    value = (new - old) / old * 100
    sign = if value >= 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(value, decimals: 1) <> "%"
  end
end

warmup = Bench.env_number("BENCH_WARMUP", 2)
time = Bench.env_number("BENCH_TIME", 5)
memory_time = Bench.env_number("BENCH_MEMORY_TIME", 1)
parallel = Bench.env_number("BENCH_PARALLEL", 4)
output = System.get_env("BENCH_OUTPUT", "bench/results/latest.md")

## 1. One-time costs (separated from steady state)

# `mix run --no-start` starts :logger before config/bench.exs applies.
Logger.configure(level: Application.get_env(:logger, :level, :error))

{tg_start_us, {:ok, _}} = :timer.tc(fn -> Application.ensure_all_started(:trace_guard) end)

{tg_reload_us, _} =
  :timer.tc(fn -> TraceGuard.Config.load!() && TraceGuard.Telemetry.attach() end)

{app_start_us, {:ok, _}} = :timer.tc(fn -> Application.ensure_all_started(:trace_guard_demo) end)

# Deterministic fixture: the same two products every run.
TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Order)
TraceGuardDemo.Repo.delete_all(TraceGuardDemo.Shop.Product)
Code.eval_file("priv/repo/seeds.exs")

Bench.configure(true)

cold =
  for {name, request} <- Bench.scenarios() do
    {us, status} = :timer.tc(fn -> Bench.request(request) end)
    {name, us, status}
  end

## 2. Sanity checks: same responses in both modes; reports only when enabled.

expected = [200, 200, 500, 200, 200]

for enabled? <- [false, true] do
  Bench.configure(enabled?)
  statuses = Enum.map(Bench.scenarios(), fn {_, request} -> Bench.request(request) end)
  statuses == expected || raise "unexpected statuses #{inspect(statuses)} (enabled: #{enabled?})"
  Process.sleep(50)
  reports = length(TraceGuard.list_reports())

  if reports != if(enabled?, do: 1, else: 0),
    do: raise("expected #{if enabled?, do: 1, else: 0} report(s), got #{reports}")
end

## 3. Steady-state benchmarks

jobs = %{
  "TraceGuard disabled" =>
    {&Bench.request/1, before_scenario: fn input -> Bench.configure(false) && input end},
  "TraceGuard enabled" =>
    {&Bench.request/1, before_scenario: fn input -> Bench.configure(true) && input end}
}

sequential =
  Benchee.run(jobs,
    inputs: Bench.scenarios(),
    warmup: warmup,
    time: time,
    memory_time: memory_time,
    percentiles: [50, 99],
    formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
  )

# Read-only scenarios only: SQLite serialises writers, so the checkout
# scenario would mostly measure database lock contention.
read_only = Enum.reject(Bench.scenarios(), fn {name, _} -> name =~ "checkout" end)

concurrent =
  Benchee.run(jobs,
    inputs: read_only,
    warmup: warmup,
    time: time,
    parallel: parallel,
    percentiles: [50, 99],
    formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
  )

## 4. Markdown summary

system = sequential.system
trace_guard_config = TraceGuard.Config.get() |> Map.from_struct() |> Map.delete(:enabled)

markdown = """
# TraceGuard request-overhead benchmark

Generated #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()} by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir #{system.elixir}, Erlang/OTP #{system.erlang}, JIT #{system.jit_enabled?}
* #{system.os}, #{system.num_cores} cores, #{system.cpu_speed}, #{system.available_memory}
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up #{warmup}s, measurement #{time}s, memory measurement #{memory_time}s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `#{inspect(trace_guard_config, limit: :infinity)}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: #{tg_start_us} µs
* Re-running config validation + telemetry attach: #{tg_reload_us} µs
* `Application.ensure_all_started(:trace_guard_demo)`: #{app_start_us} µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
#{Enum.map_join(cold, "\n", fn {name, us, status} -> "  * #{name}: #{us} µs (status #{status})" end)}

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

#{Bench.summary(sequential, "Sequential (1 process)", 1)}
#{Bench.summary(concurrent, "Concurrent (#{parallel} processes, read-only scenarios, no memory measurement)", parallel)}
"""

File.mkdir_p!(Path.dirname(output))
File.write!(output, markdown)
IO.puts("\nSummary written to #{output}\n")
IO.puts(markdown)
