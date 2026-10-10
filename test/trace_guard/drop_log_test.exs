defmodule TraceGuard.DropLogTest do
  # The bounded drop record and report_status/1. Coordination through
  # :sys.suspend/resume and telemetry events; no sleeps except where a TTL
  # must actually elapse (a few milliseconds).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, DropLog, ReportStore, Storage}

  @endpoint TraceGuard.TestApp.Endpoint

  defp id, do: Context.generate_trace_id()
  defp report, do: %{"trace_id" => id(), "events" => []}
  defp store, do: Process.whereis(ReportStore)

  setup do
    configure(max_pending_reports: 3)
    DropLog.sweep()
    on_exit(fn -> if pid = Process.whereis(ReportStore), do: :sys.resume(pid) end)
    :ok
  end

  test "report_status distinguishes stored, dropped, pending and unknown" do
    stored = report()
    {:ok, :queued} = Storage.put(stored)
    {:ok, _} = TraceGuard.await_report(stored["trace_id"], 1_000)

    :sys.suspend(store())

    pending =
      for _ <- 1..3,
          do:
            (
              r = report()
              {:ok, :queued} = Storage.put(r)
              r["trace_id"]
            )

    refused = report()
    {:error, :overloaded} = Storage.put(refused)

    # The store is suspended, so ask DropLog directly for the pending marks.
    for p <- pending, do: assert(DropLog.pending?(p))
    assert DropLog.lookup(refused["trace_id"]) == {:dropped, :overloaded}

    :sys.resume(store())
    for p <- pending, do: {:ok, _} = TraceGuard.await_report(p, 1_000)

    assert TraceGuard.report_status(stored["trace_id"]) == :stored
    assert TraceGuard.report_status(refused["trace_id"]) == {:dropped, :overloaded}
    for p <- pending, do: assert(TraceGuard.report_status(p) == :stored)
    refute Enum.any?(pending, &DropLog.pending?/1)
    assert TraceGuard.report_status(id()) == :unknown
    assert TraceGuard.report_status("nope") == {:error, :invalid_trace_id}
  end

  test "await_report/2 reports a drop that happened before the call" do
    r = report()
    :sys.suspend(store())
    for _ <- 1..3, do: Storage.put(report())
    {:error, :overloaded} = Storage.put(r)
    :sys.resume(store())

    assert TraceGuard.await_report(r["trace_id"], 50) == {:error, {:dropped, :overloaded}}
  end

  test "a request's report dropped under overload is identifiable afterwards" do
    :sys.suspend(store())
    for _ <- 1..3, do: Storage.put(report())

    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    trace = trace_id(headers)
    :sys.resume(store())

    assert TraceGuard.report_status(trace) == {:dropped, :overloaded}
  end

  test "records are bounded by count; the oldest are evicted first" do
    configure(max_drop_records: 5)

    ids =
      for _ <- 1..20,
          do:
            (
              i = id()
              DropLog.record_drop(i, :overloaded)
              i
            )

    assert DropLog.sizes().drop_records == 5
    for old <- Enum.take(ids, 15), do: assert(DropLog.lookup(old) == :none)
    for new <- Enum.take(ids, -5), do: assert(DropLog.lookup(new) == {:dropped, :overloaded})
  end

  test "concurrent writers never exceed the bound" do
    configure(max_drop_records: 50)

    1..2_000
    |> Task.async_stream(fn _ -> DropLog.record_drop(id(), :overloaded) end, max_concurrency: 64)
    |> Stream.run()

    # The guarantee is the upper bound. Racing evictions can leave fewer
    # records (by up to the number of concurrent writers; 41 to 50 have
    # been observed), so there's no fixed lower bound to assert here.
    assert DropLog.sizes().drop_records <= 50

    # Afterwards, eviction catches up and stays oldest-first: 50 sequential
    # drops leave exactly those 50 records.
    latest = for _ <- 1..50, do: tap(id(), &DropLog.record_drop(&1, :overloaded))
    assert DropLog.sizes().drop_records == 50
    for i <- latest, do: assert(DropLog.lookup(i) == {:dropped, :overloaded})
  end

  test "an expired record means unknown, and the sweep removes it" do
    configure(drop_record_ttl: 1)
    i = id()
    DropLog.record_drop(i, :overloaded)
    receive(after: (5 -> :ok))

    assert DropLog.lookup(i) == :none
    assert TraceGuard.report_status(i) == :unknown
    DropLog.sweep()
    assert DropLog.sizes().drop_records == 0
  end

  test "stale pending marks are removed, never turned into drops" do
    configure(drop_record_ttl: 1)
    i = id()
    DropLog.pending(i, ReportStore)
    receive(after: (5 -> :ok))
    DropLog.sweep()

    refute DropLog.pending?(i)
    assert DropLog.lookup(i) == :none
    assert TraceGuard.report_status(i) == :unknown
  end

  test "reasons are normalized: no arbitrary terms are kept" do
    for {reason, kept} <- [
          {:overloaded, :overloaded},
          {{:adapter_failed, :error}, {:adapter_failed, :error}},
          {{:sqlite_error, String.duplicate("x", 300)},
           {:sqlite_error, String.duplicate("x", 100)}},
          {%{password: "hunter2"}, :other},
          {{:bad, %{token: "t"}}, {:bad, :other}},
          {{1, 2, 3, 4}, :other}
        ] do
      i = id()
      DropLog.record_drop(i, reason)
      assert DropLog.lookup(i) == {:dropped, kept}
    end
  end

  test "a restarted store turns its pending submissions into per-trace :lost drops" do
    old = store()
    :sys.suspend(old)

    ids =
      for _ <- 1..3,
          do:
            (
              r = report()
              {:ok, :queued} = Storage.put(r)
              r["trace_id"]
            )

    before = Storage.stats()

    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    _ = Supervisor.which_children(TraceGuard.Supervisor)

    for i <- ids, do: assert(TraceGuard.report_status(i) == {:dropped, :lost})
    assert Storage.stats().lost - before.lost == 3
  end
end
