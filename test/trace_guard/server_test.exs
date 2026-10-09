defmodule TraceGuard.ServerTest do
  # Explicit GenServer propagation (TraceGuard.call/3 + use TraceGuard.Server)
  # against real supervised server processes and real Phoenix requests.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  alias TraceGuard.Context
  alias TraceGuard.TestApp.{InnerPricing, PlainServer, PricingServer}

  @endpoint TraceGuard.TestApp.Endpoint

  setup do
    configure(max_reports: 200)
    on_exit(fn -> Context.take() end)
    :ok
  end

  defp server_events(report),
    do: Enum.filter(report["events"], &String.starts_with?(&1["process"], "server-"))

  defp await_restart(name, old_pid) do
    ref = Process.monitor(old_pid)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, _}
    # A synchronous call to the supervisor orders us after its restart.
    _ = Supervisor.which_children(TraceGuard.TestSupervisor)
    new = Process.whereis(name)
    assert is_pid(new) and new != old_pid
    new
  end

  test "a traced call's server-side events join the caller's trace" do
    conn = get(build_conn(), "/server/quote/s1")
    report = fetch_report!(trace_id(conn))

    assert Enum.sort(query_sources(report)) == ["s1_request", "s1_server"]

    assert [start, query, stop] = server_events(report)

    assert {start["name"], query["name"], stop["name"]} ==
             {"genserver.call.start", "ecto.query", "genserver.call.stop"}

    assert Enum.uniq(Enum.map([start, query, stop], & &1["process"])) == ["server-1"]

    assert start["metadata"] == %{
             "server" => "TraceGuard.TestApp.Pricing",
             "operation" => "quote"
           }

    assert stop["outcome"] == "ok"
    assert report["tasks"]["processes"] == 1

    # The request's arguments are never recorded.
    refute Jason.encode!(report) =~ "hunter2"
  end

  test "concurrent callers of the same server never mix events" do
    results =
      1..20
      |> Task.async_stream(
        fn i ->
          conn = get(build_conn(), "/server/quote/c#{i}")
          {"c#{i}", trace_id(conn)}
        end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, r} -> r end)

    for {tag, id} <- results do
      assert Enum.sort(id |> fetch_report!() |> query_sources()) == [
               "#{tag}_request",
               "#{tag}_server"
             ]
    end
  end

  test "unrelated server activity is never attached to a trace" do
    Context.start(Context.generate_trace_id(), %{})

    # Interleave background work with a traced call from this process.
    GenServer.cast(PricingServer, :background)
    send(Process.whereis(PricingServer), :background)
    assert GenServer.call(PricingServer, :plain) == :plain
    assert {:ok, "traced"} = TraceGuard.call(PricingServer, {:quote, "traced", nil})
    GenServer.cast(PricingServer, :background)
    assert GenServer.call(PricingServer, :plain) == :plain

    assert {:reported, id} = TraceGuard.EventCollector.finish(500)
    assert query_sources(fetch_report!(id)) == ["traced"]

    # No trace context remains in the server between calls.
    assert GenServer.call(PricingServer, :context) == nil
    {:dictionary, dict} = Process.info(Process.whereis(PricingServer), :dictionary)
    refute Enum.any?(dict, fn {key, _} -> key == {Context, :ctx} end)
  end

  @tag :capture_log
  test "a failing callback is recorded, crashes the server as usual, and the server recovers" do
    old = Process.whereis(PricingServer)
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/server/fail") end)

    # GenServer.call exits the caller, so (like any exit) no response header.
    assert trace_id(headers) == nil
    report = fetch_report_where!(route: "/server/fail")

    assert report["failure"]["kind"] == "exit"
    assert report["failure"]["exception"] == "TraceGuard.TestApp.BoomError"

    assert report["failure"]["message"] =~
             "GenServer.call/3 exited: process crashed: pricing failed"

    refute report["failure"]["message"] =~ "TraceGuard.Server"

    exception = Enum.find(report["events"], &(&1["name"] == "genserver.call.exception"))
    assert exception["process"] == "server-1"
    assert exception["metadata"]["exception"] == "TraceGuard.TestApp.BoomError"
    assert "before_server_crash" in query_sources(report)

    # Supervisor restart: traced calls work against the new process.
    await_restart(PricingServer, old)
    Context.start(Context.generate_trace_id(), %{})
    assert {:ok, "after_restart"} = TraceGuard.call(PricingServer, {:quote, "after_restart", nil})
    assert {:reported, id} = TraceGuard.EventCollector.finish(500)
    assert query_sources(fetch_report!(id)) == ["after_restart"]
  end

  @tag :capture_log
  test "a timeout exits the caller as usual; the server's late events are dropped" do
    {500, _headers, _} =
      assert_error_sent(500, fn -> get(build_conn(), "/server/timeout/50") end)

    assert_received {:blocked, server}
    report = fetch_report_where!(route: "/server/timeout/:ms")
    assert report["failure"]["kind"] == "exit"
    assert report["failure"]["message"] =~ "GenServer.call/3 exited: exit: :timeout"

    # The server is still busy with the call; release it. Its events arrive
    # after the request completed, so they are dropped, and it keeps serving.
    send(server, :go)
    assert GenServer.call(PricingServer, :plain) == :plain
    refute "after_block" in query_sources(fetch_report!(report["trace_id"]))
  end

  test "a throw-return from a traced callback is an ordinary reply" do
    Context.start(Context.generate_trace_id(), %{})
    assert TraceGuard.call(PricingServer, {:throw_reply, :thrown}) == :thrown
    assert {:reported, id} = TraceGuard.EventCollector.finish(500)
    report = fetch_report!(id)

    assert [_, _, %{"name" => "genserver.call.stop", "outcome" => "ok"}] = server_events(report)
  end

  test "nested traced calls report into the same trace" do
    conn = get(build_conn(), "/server/nested")
    report = fetch_report!(trace_id(conn))

    assert Enum.sort(query_sources(report)) == ["inner_n", "outer_n"]
    labels = report |> server_events() |> Enum.map(& &1["process"]) |> Enum.uniq() |> Enum.sort()
    assert labels == ["server-1", "server-2"]
  end

  test "work after {:noreply, _} (deferred reply) is not traced" do
    conn = get(build_conn(), "/server/reply_later")
    report = fetch_report!(trace_id(conn))
    assert query_sources(report) == ["before_noreply_d"]
  end

  test "untraced callers and ordinary calls behave exactly like GenServer.call/3" do
    assert Context.current() == nil
    assert TraceGuard.call(PricingServer, {:quote, "untraced", nil}) == {:ok, "untraced"}
    assert GenServer.call(PricingServer, {:quote, "plain", nil}) == {:ok, "plain"}
    assert GenServer.call(PricingServer, :context) == nil
  end

  test "disabled TraceGuard still delivers the call" do
    configure(enabled: false)
    Context.start(Context.generate_trace_id(), %{})
    assert TraceGuard.call(PricingServer, {:quote, "disabled", nil}) == {:ok, "disabled"}
  end

  @tag :capture_log
  test "a server without `use TraceGuard.Server` rejects traced calls the same way every time" do
    old = Process.whereis(PlainServer)
    assert {{:function_clause, _}, _} = catch_exit(TraceGuard.call(PlainServer, :ping))
    await_restart(PlainServer, old)
    assert GenServer.call(PlainServer, :ping) == :pong
  end

  test "calls to a server that is down exit with :noproc, as GenServer.call/3 does" do
    assert {:noproc, _} = catch_exit(TraceGuard.call(:no_such_server, :ping))
    assert {:noproc, _} = catch_exit(GenServer.call(:no_such_server, :ping))
  end

  test "a token whose budget is unusable never breaks the server callback" do
    # Simulates a token from another node (whose :atomics ref is invalid
    # here): recording must fail closed, not raise in handle_call/3.
    Context.start(Context.generate_trace_id(), %{})
    token = TraceGuard.Propagation.capture()
    broken = %{token | counter: make_ref()}

    assert GenServer.call(PricingServer, {TraceGuard.Server, broken, {:quote, "broken", nil}}) ==
             {:ok, "broken"}

    assert GenServer.call(PricingServer, :plain) == :plain
  end

  test "server-side events respect the shared task budget" do
    configure(max_events: 3)
    Context.start(Context.generate_trace_id(), %{})
    for i <- 1..10, do: TraceGuard.call(InnerPricing, {:quote, "b#{i}", nil})
    assert {:reported, id} = TraceGuard.EventCollector.finish(500)
    report = fetch_report!(id)

    assert length(server_events(report)) <= 3
    assert report["events_dropped"] >= 27
  end
end
