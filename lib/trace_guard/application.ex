defmodule TraceGuard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast on invalid configuration, then attach telemetry handlers.
    TraceGuard.Config.load!()

    children = [TraceGuard.ReportStore]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: TraceGuard.Supervisor) do
      TraceGuard.Telemetry.attach()
      {:ok, pid}
    end
  end

  @impl true
  def stop(_state) do
    TraceGuard.Telemetry.detach()
  end
end
