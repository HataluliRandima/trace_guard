defmodule TraceGuard.TelemetryTest do
  use ExUnit.Case, async: false

  import TraceGuard.TestHelpers

  # Regression: detach + attach_many is not atomic, and concurrent callers
  # used to crash with {:error, :already_exists}.
  test "attach/0 is safe to call concurrently" do
    configure()

    results =
      1..20
      |> Task.async_stream(fn _ -> TraceGuard.Telemetry.attach() end, max_concurrency: 20)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :ok))

    handlers = :telemetry.list_handlers([:phoenix, :router_dispatch, :exception])
    assert length(Enum.filter(handlers, &(&1.id == {TraceGuard.Telemetry, :handlers}))) == 1
  end

  @tag :capture_log
  test "an internal handler error is contained: no detach, no recursive events" do
    configure()
    TraceGuard.Context.start(TraceGuard.Context.generate_trace_id(), %{})
    on_exit(fn -> TraceGuard.Context.take() end)

    # Metadata missing the documented keys makes TraceGuard's handler raise.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :telemetry.execute([:phoenix, :router_dispatch, :exception], %{}, %{unexpected: true})
      end)

    assert log =~ "TraceGuard ignored an internal error"
    assert TraceGuard.Context.current().events == []
    assert TraceGuard.Context.current().failure == nil

    handlers = :telemetry.list_handlers([:phoenix, :router_dispatch, :exception])
    assert Enum.any?(handlers, &(&1.id == {TraceGuard.Telemetry, :handlers}))
  end
end
