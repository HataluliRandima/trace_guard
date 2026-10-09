import Config

for {endpoint, debug_errors} <- [
      {TraceGuard.TestApp.Endpoint, false},
      # Plug.Debugger is wired in at compile time, so this must live here.
      {TraceGuard.TestApp.DebugEndpoint, true}
    ] do
  config :trace_guard, endpoint,
    secret_key_base: String.duplicate("a", 64),
    render_errors: [formats: [json: TraceGuard.TestApp.ErrorJSON], layout: false],
    debug_errors: debug_errors,
    server: false
end

config :logger, level: :warning
config :phoenix, :json_library, Jason
