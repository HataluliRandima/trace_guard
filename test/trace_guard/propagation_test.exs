defmodule TraceGuard.PropagationTest do
  # Task propagation across real process boundaries. Coordination uses
  # messages and monitors, not sleeps. Not async: global config and the
  # shared collector supervisor are inspected.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  alias TraceGuard.{Context, EventCollector}

  @endpoint TraceGuard.TestApp.Endpoint

  setup do
    configure(max_reports: 200)
    on_exit(fn -> Context.take() end)
    :ok
  end

  defp task_events(report), do: Enum.reject(report["events"], &(&1["process"] == "request"))

  describe "through a real Phoenix request" do
    test "events from a wrapped task appear in the originating trace" do
      {500, headers, _} =
        assert_error_sent(500, fn -> get(build_conn(), "/tasks/await/r1/true") end)

      report = fetch_report!(trace_id(headers))

      sources = query_sources(report)
      assert "r1_task_a" in sources
      assert "r1_task_b" in sources
      assert "r1_request" in sources

      # Unwrapped tasks inherit nothing (opt-in only).
      refute "r1_unwrapped" in sources

      assert report["tasks"] == %{"status" => "complete", "processes" => 2, "events" => 6}

      task_labels = report |> task_events() |> Enum.map(& &1["process"]) |> Enum.uniq()
      assert Enum.sort(task_labels) == ["task-1", "task-2"]

      for label <- task_labels do
        names = for e <- report["events"], e["process"] == label, do: e["name"]
        assert names == ["task.start", "ecto.query", "task.stop"]
      end

      # One merged timeline, renumbered and ordered by monotonic time.
      assert Enum.map(report["events"], & &1["seq"]) == Enum.to_list(1..length(report["events"]))
      offsets = Enum.map(report["events"], & &1["offset_us"])
      assert offsets == Enum.sort(offsets)

      # Task events come after the router started dispatching and before
      # the exception it observed.
      index = fn name -> Enum.find_index(report["events"], &(&1["name"] == name)) end
      first_task = Enum.find_index(report["events"], &(&1["process"] != "request"))
      assert index.("phoenix.router_dispatch.start") < first_task
      assert first_task < index.("phoenix.router_dispatch.exception")
    end

    test "simultaneous requests with tasks do not contaminate each other" do
      results =
        1..20
        |> Task.async_stream(
          fn i ->
            {500, headers, _} =
              assert_error_sent(500, fn -> get(build_conn(), "/tasks/await/c#{i}/true") end)

            {"c#{i}", trace_id(headers)}
          end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {tag, id} <- results do
        sources = id |> fetch_report!() |> query_sources()

        assert Enum.sort(sources) ==
                 Enum.sort(["#{tag}_task_a", "#{tag}_task_b", "#{tag}_request"])
      end
    end

    test "nested propagation reports grandchildren into the same trace" do
      conn = get(build_conn(), "/tasks/nested")
      report = fetch_report!(trace_id(conn))

      assert Enum.sort(query_sources(report)) == ["child", "grandchild"]
      child = Enum.find(report["events"], &(&1["metadata"]["source"] == "child"))
      grandchild = Enum.find(report["events"], &(&1["metadata"]["source"] == "grandchild"))
      assert child["process"] != grandchild["process"]
      assert report["tasks"]["processes"] == 2
    end

    test "repeated wraps and arity-1 functions (async_stream) share the trace" do
      conn = get(build_conn(), "/tasks/repeated")
      report = fetch_report!(trace_id(conn))

      assert Enum.sort(query_sources(report)) == ["first", "s1", "s2", "s3", "second"]
      assert report["tasks"]["processes"] == 5
    end

    @tag :capture_log
    test "a failing child is recorded and its failure still propagates" do
      {500, headers, _} =
        assert_error_sent(500, fn -> get(build_conn(), "/tasks/child_fails") end)

      # Task.await exits the request process. Plug only wraps :error
      # exceptions, so (as for throw/exit in Phase 1) Phoenix renders with
      # the endpoint's original conn: no response header, report in the store.
      assert trace_id(headers) == nil
      [%{"trace_id" => id}] = TraceGuard.list_reports()
      report = fetch_report!(id)

      # Task.await exits the request process with the child's crash reason.
      assert report["failure"]["kind"] == "exit"
      assert report["failure"]["captured_by"] == "phoenix.router_dispatch.exception"

      task_exception = Enum.find(report["events"], &(&1["name"] == "task.exception"))
      assert task_exception["outcome"] == "error"

      assert task_exception["metadata"] == %{
               "kind" => "error",
               "exception" => "TraceGuard.TestApp.BoomError"
             }

      assert "before_child_failure" in query_sources(report)

      # The child's message is in the exit reason; it is scrubbed like any
      # other exception message.
      refute Jason.encode!(report) =~ "abc123"
    end

    test "a child that finishes after the request completed is not added to the report" do
      {:ok, collectors_before} = {:ok, task_collector_count()}
      conn = get(build_conn(), "/tasks/late")
      assert conn.status == 500
      assert_received {:late_child, child}

      report = fetch_report!(trace_id(conn))
      assert query_sources(report) == ["request_before_late_child"]

      # The collector was drained and stopped with the request.
      assert task_collector_count() == collectors_before

      # The child still runs to completion; its late events are dropped.
      send(child, :go)
      assert_receive :late_child_done
      await_exit(child)
      assert fetch_report!(trace_id(conn)) == report
    end

    test "task events are bounded across all task processes" do
      configure(max_events: 20)
      conn = get(build_conn(), "/tasks/flood/500")
      report = fetch_report!(trace_id(conn))

      ordinary = Enum.reject(report["events"], &(&1["name"] in ["request.start", "request.stop"]))
      assert length(ordinary) <= 20
      # 4 tasks x (500 queries + start + stop) were emitted; nearly all dropped.
      assert report["events_dropped"] >= 4 * 502 - 20
    end

    test "successful requests discard their collector without waiting" do
      before = task_collector_count()
      conn = get(build_conn(), "/tasks/ok")
      assert json_response(conn, 200) == %{"ok" => true}
      assert TraceGuard.get_report(trace_id(conn)) == {:error, :not_found}

      # Discard is asynchronous; wait for the collector itself to exit.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(TraceGuard.TaskCollectors),
          do: await_exit(pid)

      assert task_collector_count() <= before
      assert Context.current() == nil
    end

    test "Phase 1 behaviour is unchanged for requests that never wrap" do
      {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
      report = fetch_report!(trace_id(headers))
      assert report["tasks"] == nil
      assert Enum.all?(report["events"], &(&1["process"] == "request"))
    end
  end

  describe "wrap/1 contract" do
    test "returns the function unchanged outside a trace" do
      fun = fn -> :ok end
      assert TraceGuard.wrap(fun) == fun
      assert_raise FunctionClauseError, fn -> TraceGuard.wrap(fn _, _ -> :ok end) end
    end

    test "preserves results, raises, throws and exits exactly" do
      Context.start(Context.generate_trace_id(), %{})

      assert Task.async(TraceGuard.wrap(fn -> {:ok, 42} end)) |> Task.await() == {:ok, 42}

      for {fun, kind} <- [
            {fn -> raise ArgumentError, "bad" end, :error},
            {fn -> throw(:thrown) end, :throw},
            {fn -> exit(:gone) end, :exit}
          ] do
        plain = run_isolated(fun)
        wrapped = run_isolated(TraceGuard.wrap(fun))
        assert {^kind, _, _} = plain
        assert normalize_stack(wrapped) == normalize_stack(plain)
      end
    end

    @tag :capture_log
    test "linked task crashes keep their normal exit reason" do
      Context.start(Context.generate_trace_id(), %{})
      fun = fn -> raise RuntimeError, "linked" end

      reason_of = fn f ->
        {pid, ref} =
          spawn_monitor(fn ->
            Process.flag(:trap_exit, true)
            task = Task.async(f)
            receive do: ({:EXIT, _, reason} -> exit({:task_exit, reason, task.ref}))
          end)

        receive do: ({:DOWN, ^ref, :process, ^pid, {:task_exit, reason, _}} -> reason)
      end

      # The linked parent receives the same exception either way.
      {%RuntimeError{message: "linked"}, [_ | _]} = reason_of.(TraceGuard.wrap(fun))
      {%RuntimeError{message: "linked"}, [_ | _]} = reason_of.(fun)
    end

    test "inside the process that owns the trace, the function simply runs" do
      id = Context.generate_trace_id()
      Context.start(id, %{})
      wrapped = TraceGuard.wrap(fn -> EventCollector.record("inline", "custom", %{}) end)

      assert wrapped.() == :ok
      assert %Context{trace_id: ^id, role: :request} = ctx = Context.current()
      assert [%{name: "inline", process: "request"}] = ctx.events
    end

    test "only the token is propagated, never other process state" do
      Process.put(:secret_session, "do-not-copy")
      Logger.metadata(user_email: "a@example.com")
      Context.start(Context.generate_trace_id(), %{headers: %{"authorization" => "Bearer x"}})

      seen =
        Task.async(
          TraceGuard.wrap(fn ->
            {Process.get(:secret_session), Logger.metadata()[:user_email], Context.current()}
          end)
        )
        |> Task.await()

      assert {nil, nil, %Context{role: :task, request: %{}} = task_ctx} = seen

      assert Map.keys(Map.from_struct(task_ctx.tasks)) |> Enum.sort() == [
               :collector,
               :counter,
               :trace_id
             ]

      Process.delete(:secret_session)
    end

    test "a wrapped function run in another request's process reports to its own trace" do
      a = Context.generate_trace_id()
      Context.start(a, %{})
      wrapped = TraceGuard.wrap(fn -> EventCollector.record("for_a", "custom", %{}) end)

      parent = self()

      task =
        Task.async(fn ->
          b = Context.generate_trace_id()
          Context.start(b, %{})
          wrapped.()
          send(parent, {:b_events, Context.current().trace_id == b, Context.current().events})
        end)

      Task.await(task)
      assert_received {:b_events, true, []}

      assert {:reported, ^a} = EventCollector.finish(500)

      assert [%{"name" => "for_a"}] =
               a |> fetch_report!() |> task_events() |> Enum.filter(&(&1["name"] == "for_a"))
    end

    test "the task context is removed when the wrapped function returns or fails" do
      Context.start(Context.generate_trace_id(), %{})

      check = fn f ->
        Task.async(fn ->
          run_isolated(TraceGuard.wrap(f))
          Context.current()
        end)
        |> Task.await()
      end

      assert check.(fn -> :ok end) == nil
      assert check.(fn -> raise "boom" end) == nil
    end
  end

  describe "lifecycle and bounds" do
    test "the collector stops when the owning process exits" do
      parent = self()

      owner =
        spawn(fn ->
          Context.start(Context.generate_trace_id(), %{})
          TraceGuard.wrap(fn -> :ok end)
          send(parent, {:collector, Context.current().tasks.collector})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:collector, collector}
      assert Process.alive?(collector)
      send(owner, :exit)
      await_exit(collector)
    end

    test "the collector stops after :task_collector_lifetime" do
      configure(task_collector_lifetime: 10)
      Context.start(Context.generate_trace_id(), %{})
      TraceGuard.wrap(fn -> :ok end)
      await_exit(Context.current().tasks.collector)

      # A trace whose collector expired still completes, with a limitation.
      assert {:reported, id} = EventCollector.finish(500)
      report = fetch_report!(id)
      assert report["tasks"]["status"] == "unavailable"
      assert Enum.any?(report["limitations"], &(&1 =~ "collector had already stopped"))
    end

    test "a stale context replaced by a new request stops its collector" do
      Context.start(Context.generate_trace_id(), %{})
      TraceGuard.wrap(fn -> :ok end)
      collector = Context.current().tasks.collector

      Context.start(Context.generate_trace_id(), %{})
      await_exit(collector)
      assert Context.current().tasks == nil
    end

    test "draining never waits longer than :task_drain_timeout" do
      configure(task_drain_timeout: 50)
      Context.start(Context.generate_trace_id(), %{})
      TraceGuard.wrap(fn -> :ok end)
      collector = Context.current().tasks.collector
      :sys.suspend(collector)

      {elapsed_us, {:reported, id}} = :timer.tc(fn -> EventCollector.finish(500) end)
      assert elapsed_us < 1_000_000

      report = fetch_report!(id)
      assert report["tasks"]["status"] == "timeout"
      assert Enum.any?(report["limitations"], &(&1 =~ "task_drain_timeout (50 ms)"))

      # The timed-out collector is told to stop and does once resumed.
      :sys.resume(collector)
      await_exit(collector)
    end

    test "without a collector supervisor, wrap/1 degrades to the plain function" do
      :ok = Supervisor.terminate_child(TraceGuard.Supervisor, TraceGuard.TaskCollectors)

      on_exit(fn -> Supervisor.restart_child(TraceGuard.Supervisor, TraceGuard.TaskCollectors) end)

      Context.start(Context.generate_trace_id(), %{})
      fun = fn -> :ok end
      assert TraceGuard.wrap(fun) == fun

      assert {:reported, id} = EventCollector.finish(500)
      report = fetch_report!(id)
      assert report["tasks"]["status"] == "collector_limit_reached"
    end
  end

  defp run_isolated(fun) do
    try do
      {:returned, fun.(), nil}
    catch
      kind, reason -> {kind, reason, __STACKTRACE__}
    end
  end

  # The wrapper adds frames below the original raise; the reason and the
  # frame that raised must be identical.
  defp normalize_stack({kind, reason, [top | _]}), do: {kind, reason, top}
end
