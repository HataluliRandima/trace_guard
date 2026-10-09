TraceGuard.Config.put!(TraceGuard.TestHelpers.base_config())
TraceGuard.Telemetry.attach()

{:ok, _} = TraceGuard.TestApp.Endpoint.start_link()
{:ok, _} = TraceGuard.TestApp.DebugEndpoint.start_link()
{:ok, _} = Task.Supervisor.start_link(name: TraceGuard.TestApp.TaskSup)

{:ok, _} =
  Supervisor.start_link(
    [
      TraceGuard.TestStorage,
      Supervisor.child_spec(
        {TraceGuard.TestApp.Pricing, TraceGuard.TestApp.PricingServer},
        id: :pricing
      ),
      Supervisor.child_spec(
        {TraceGuard.TestApp.Pricing, TraceGuard.TestApp.InnerPricing},
        id: :inner_pricing
      ),
      {TraceGuard.TestApp.PlainServer, TraceGuard.TestApp.PlainServer}
    ],
    strategy: :one_for_one,
    name: TraceGuard.TestSupervisor
  )

ExUnit.start()
