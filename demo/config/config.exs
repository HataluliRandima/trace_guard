# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :trace_guard_demo,
  ecto_repos: [TraceGuardDemo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :trace_guard_demo, TraceGuardDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: TraceGuardDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TraceGuardDemo.PubSub,
  live_view: [signing_salt: "u7yow0Ho"]

# TraceGuard diagnostics. See ../docs/configuration.md.
config :trace_guard,
  ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]],
  # Demo only: SQL text (never parameter values) makes the timeline easier
  # to read. Off by default because literals can be inlined into SQL.
  capture_sql: true,
  # Demo only: these headers are captured to show that sensitive ones are
  # redacted. Capturing credentials is not recommended.
  capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"],
  redact_keys: ["card_number", "cvc"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :trace_guard_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
