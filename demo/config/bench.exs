import Config

# Production-like settings for bench/request_overhead.exs: no code reloader,
# no SQL sandbox, no debug logging and no dev-only routes. The TraceGuard
# settings come from config/config.exs and are identical to dev.
config :trace_guard_demo, TraceGuardDemo.Repo,
  database: Path.expand("../trace_guard_demo_bench.db", __DIR__),
  pool_size: 5

config :trace_guard_demo, TraceGuardDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "bench-only-secret-key-base-0000000000000000000000000000000000000000",
  debug_errors: false,
  server: false

config :logger, level: :error
