# :httpc is used by the real-HTTP test.
Mix.ensure_application!(:inets)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(TraceGuardDemo.Repo, :manual)
