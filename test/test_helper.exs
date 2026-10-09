TraceGuard.Config.put!(TraceGuard.TestHelpers.base_config())
TraceGuard.Telemetry.attach()

{:ok, _} = TraceGuard.TestApp.Endpoint.start_link()
{:ok, _} = TraceGuard.TestApp.DebugEndpoint.start_link()
{:ok, _} = Task.Supervisor.start_link(name: TraceGuard.TestApp.TaskSup)

ExUnit.start()
