defmodule TraceGuard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast on invalid configuration, then attach telemetry handlers.
    config = TraceGuard.Config.load!()
    TraceGuard.Storage.init_counters()

    children =
      storage_children(config) ++
        [
          Supervisor.child_spec(
            {DynamicSupervisor,
             name: TraceGuard.TaskCollectors,
             strategy: :one_for_one,
             max_children: config.max_task_collectors},
            id: TraceGuard.TaskCollectors
          )
        ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: TraceGuard.Supervisor) do
      TraceGuard.Telemetry.attach()
      {:ok, pid}
    end
  end

  # The adapter configured at boot is supervised by TraceGuard if it exports
  # child_spec/1 (the default ReportStore does). Adapters without one manage
  # their own processes.
  defp storage_children(config) do
    {adapter, opts} =
      case config.storage do
        {module, opts} -> {module, opts}
        module -> {module, []}
      end

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :child_spec, 1),
      do: [adapter.child_spec(opts)],
      else: []
  end

  @impl true
  def stop(_state) do
    TraceGuard.Telemetry.detach()
  end
end
