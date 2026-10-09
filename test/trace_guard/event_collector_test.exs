defmodule TraceGuard.EventCollectorTest do
  # Not async: changes global TraceGuard config.
  use ExUnit.Case, async: false

  import TraceGuard.TestHelpers

  alias TraceGuard.{Config, Context, EventCollector, TraceBuilder}

  setup do
    configure()
    on_exit(fn -> Context.take() end)
    :ok
  end

  test "record/4 without an active context is ignored" do
    assert EventCollector.record("x", "custom", %{}) == :no_context
    assert EventCollector.put_failure(%{}) == :no_context
    assert EventCollector.finish(500) == :no_context
  end

  test "events are ordered and offsets/durations are computed from monotonic time" do
    Context.start(Context.generate_trace_id(), %{method: "GET"})
    EventCollector.record("first", "custom", %{})
    Process.sleep(5)

    EventCollector.record("second", "custom", %{},
      duration: System.convert_time_unit(1500, :microsecond, :native)
    )

    Process.sleep(5)
    EventCollector.record("third", "custom", %{}, outcome: "ok")

    report = TraceBuilder.build(Context.take(), 500, Config.get())
    [first, second, third] = report["events"]

    assert Enum.map(report["events"], & &1["name"]) == ["first", "second", "third"]
    assert Enum.map(report["events"], & &1["seq"]) == [1, 2, 3]
    assert first["offset_us"] >= 0
    assert second["offset_us"] - first["offset_us"] >= 5_000
    assert third["offset_us"] - second["offset_us"] >= 5_000
    assert second["duration_us"] == 1500
    assert first["duration_us"] == nil
    assert third["outcome"] == "ok"
    assert report["duration_us"] >= third["offset_us"]
  end

  test "events observed at the same monotonic instant keep observation order" do
    ctx = Context.start(Context.generate_trace_id(), %{})
    now = ctx.started_mono

    events =
      for {name, seq} <- [{"b", 2}, {"a", 1}, {"c", 3}] do
        %{seq: seq, name: name, type: "t", at: now, duration: nil, outcome: nil, metadata: %{}}
      end

    report = TraceBuilder.build(%{ctx | events: events}, 500, Config.get())
    assert Enum.map(report["events"], & &1["name"]) == ["a", "b", "c"]
    Context.take()
  end

  test "ordinary events are bounded by :max_events; lifecycle events are kept" do
    configure(max_events: 3)
    Context.start(Context.generate_trace_id(), %{})

    results = for i <- 1..10, do: EventCollector.record("e#{i}", "custom", %{})
    assert results == List.duplicate(:ok, 3) ++ List.duplicate(:dropped, 7)
    assert EventCollector.record("request.stop", "request", %{}, lifecycle: true) == :ok

    report = TraceBuilder.build(Context.take(), 500, Config.get())
    assert Enum.map(report["events"], & &1["name"]) == ["e1", "e2", "e3", "request.stop"]
    assert report["events_dropped"] == 7
    assert Enum.any?(report["limitations"], &(&1 =~ "7 event(s) were dropped"))
  end

  test "the first failure is kept" do
    Context.start(Context.generate_trace_id(), %{})
    EventCollector.put_failure(%{captured_by: "first"})
    EventCollector.put_failure(%{captured_by: "second"})
    assert Context.current().failure == %{captured_by: "first"}
  end

  test "finish/1 stores a report only for failures and always clears the context" do
    id = Context.generate_trace_id()
    Context.start(id, %{})
    assert EventCollector.finish(200) == :ok
    assert Context.current() == nil
    assert TraceGuard.get_report(id) == {:error, :not_found}

    id = Context.generate_trace_id()
    Context.start(id, %{})
    assert EventCollector.finish(503) == {:reported, id}
    assert Context.current() == nil
    assert fetch_report!(id)["outcome"] == "error_status"
  end
end
