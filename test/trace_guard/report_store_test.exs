defmodule TraceGuard.ReportStoreTest do
  # Admission control, mailbox bounds and restarts of the default adapter.
  # Coordination uses :sys.suspend/resume, monitors and telemetry events.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, ReportStore, Storage}

  @endpoint TraceGuard.TestApp.Endpoint

  defp report, do: %{"trace_id" => Context.generate_trace_id(), "events" => []}
  defp store_pid, do: Process.whereis(ReportStore)
  # Condition wait for state with no notification of its own.
  defp wait_until(fun, attempts \\ 1_000) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> receive(after: (1 -> wait_until(fun, attempts - 1)))
    end
  end

  defp queue_len, do: store_pid() |> Process.info(:message_queue_len) |> elem(1)

  setup do
    configure(max_pending_reports: 10, max_reports: 5)
    on_exit(fn -> if pid = Process.whereis(ReportStore), do: :sys.resume(pid) end)
    :ok
  end

  test "a burst of submissions is admitted up to :max_pending_reports, the rest refused" do
    handler = attach_report_events()
    before = Storage.stats()
    :sys.suspend(store_pid())

    # 200 concurrent submitters against a stalled store.
    results =
      1..200
      |> Task.async_stream(
        fn _ ->
          r = report()
          {r["trace_id"], Storage.put(r)}
        end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {admitted, refused} = Enum.split_with(results, fn {_, result} -> result == {:ok, :queued} end)
    assert length(admitted) == 10
    assert Enum.all?(refused, fn {_, result} -> result == {:error, :overloaded} end)

    # The mailbox holds exactly the admitted submissions, not 200.
    assert queue_len() == 10

    # Every refusal was announced with its trace ID.
    for {id, _} <- refused, do: assert_receive({:report_event, {:dropped, :overloaded}, ^id})

    :sys.resume(store_pid())
    for {id, _} <- admitted, do: assert_receive({:report_event, :stored, ^id})
    :telemetry.detach(handler)

    after_stats = Storage.stats()
    assert after_stats.submitted - before.submitted == 200
    assert after_stats.accepted - before.accepted == 10
    assert after_stats.stored - before.stored == 10
    assert after_stats.dropped_overloaded - before.dropped_overloaded == 190
    assert after_stats.pending == 0
    # Retention bound holds independently of admission.
    assert after_stats.retained == 5
    assert after_stats.evicted - before.evicted >= 5
  end

  test "admission frees up as the store catches up" do
    :sys.suspend(store_pid())
    for _ <- 1..10, do: assert({:ok, :queued} = Storage.put(report()))
    assert {:error, :overloaded} = Storage.put(report())

    handler = attach_report_events()
    :sys.resume(store_pid())
    for _ <- 1..10, do: assert_receive({:report_event, :stored, _})
    :telemetry.detach(handler)

    assert {:ok, :queued} = Storage.put(report())
  end

  test "an overloaded store drops the report but not the request's semantics" do
    handler = attach_report_events()
    :sys.suspend(store_pid())
    for _ <- 1..10, do: Storage.put(report())

    {500, headers, body} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
    id = trace_id(headers)

    assert_receive {:report_event, {:dropped, :overloaded}, ^id}
    :sys.resume(store_pid())
    assert TraceGuard.await_report(id, 100) == {:error, :timeout}
    assert TraceGuard.get_report(id) == {:error, :not_found}
    :telemetry.detach(handler)
  end

  test "await_report/2 reports a drop that happens while waiting" do
    :sys.suspend(store_pid())
    for _ <- 1..10, do: Storage.put(report())
    r = report()
    waiter = Task.async(fn -> TraceGuard.await_report(r["trace_id"], 2_000) end)

    # Proceed once the waiter has subscribed (its handler is registered);
    # it is then blocked reading the suspended store.
    wait_until(fn ->
      [:trace_guard, :report, :dropped]
      |> :telemetry.list_handlers()
      |> Enum.any?(&match?({TraceGuard, :await_report, _}, &1.id))
    end)

    assert {:error, :overloaded} = Storage.put(r)
    assert Task.await(waiter) == {:error, {:dropped, :overloaded}}
  end

  test "a store restart loses queued submissions, counts them, and recovers" do
    old = store_pid()
    :sys.suspend(old)

    ids =
      for _ <- 1..4 do
        r = report()
        {:ok, :queued} = Storage.put(r)
        r["trace_id"]
      end

    before = Storage.stats()
    lost_before = before.lost

    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    # The supervisor restarts the store when it handles the exit signal;
    # a synchronous call to the supervisor orders us after that.
    _ = Supervisor.which_children(TraceGuard.Supervisor)
    new = store_pid()
    assert is_pid(new) and new != old

    stats = Storage.stats()
    assert stats.lost - lost_before == 4
    assert stats.pending == 0
    for id <- ids, do: assert(TraceGuard.get_report(id) == {:error, :not_found})

    r = report()
    assert {:ok, :queued} = Storage.put(r)
    assert {:ok, ^r} = TraceGuard.await_report(r["trace_id"], 1_000)
  end

  @tag :capture_log
  test "with the store stopped: submissions are refused, reads do not exit, requests are unaffected" do
    :ok = Supervisor.terminate_child(TraceGuard.Supervisor, ReportStore)
    on_exit(fn -> Supervisor.restart_child(TraceGuard.Supervisor, ReportStore) end)

    assert Storage.put(report()) == {:error, :unavailable}
    assert TraceGuard.get_report(Context.generate_trace_id()) == {:error, :unavailable}
    assert TraceGuard.list_reports() == []
    assert TraceGuard.clear_reports() == {:error, :unavailable}
    assert %{available: false} = TraceGuard.report_stats()

    handler = attach_report_events()
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    id = trace_id(headers)
    assert_receive {:report_event, {:dropped, :unavailable}, ^id}
    :telemetry.detach(handler)
  end
end
