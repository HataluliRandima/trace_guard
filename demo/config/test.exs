import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :trace_guard_demo, TraceGuardDemo.Repo,
  database: Path.expand("../trace_guard_demo_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  stacktrace: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :trace_guard_demo, TraceGuardDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Syo4BKjuj50MExM3KNqw+uXehuPohJTALXKbN24m1owZA2WCARl2DdgA1qwWQyZo",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :trace_guard_demo, expose_trace_reports: true

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
