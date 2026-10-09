defmodule TraceGuardDemo.Repo do
  use Ecto.Repo,
    otp_app: :trace_guard_demo,
    adapter: Ecto.Adapters.SQLite3
end
