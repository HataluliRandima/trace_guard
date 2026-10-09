defmodule TraceGuard.Storage.ReportStoreContractTest do
  use TraceGuard.StorageContract, storage: TraceGuard.ReportStore
end

defmodule TraceGuard.Storage.TestStorageContractTest do
  use TraceGuard.StorageContract, storage: {TraceGuard.TestStorage, max: 3}
end

defmodule TraceGuard.StorageTest do
  # The tracing engine against a non-default adapter, and the facade's
  # handling of misbehaving adapters.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  @endpoint TraceGuard.TestApp.Endpoint

  defp failing_request do
    {500, headers, body} = assert_error_sent(500, fn -> get(build_conn(), "/crash") end)
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
    trace_id(headers)
  end

  test "the engine stores through the configured adapter, not ReportStore" do
    configure()
    ids_in_report_store = Enum.map(TraceGuard.list_reports(), & &1["trace_id"])

    configure(storage: {TraceGuard.TestStorage, max: 3})
    TraceGuard.clear_reports()
    id = failing_request()

    assert {:ok, %{"trace_id" => ^id}} = TraceGuard.TestStorage.get(id, [])
    assert {:ok, %{"trace_id" => ^id}} = TraceGuard.get_report(id)

    configure()
    assert Enum.map(TraceGuard.list_reports(), & &1["trace_id"]) == ids_in_report_store
  end

  @tag :capture_log
  test "adapter failures never replace the application's exception" do
    for {mode, reason} <- [
          overloaded: :overloaded,
          raise: {:adapter_failed, :error},
          exit: {:adapter_failed, :exit},
          bad_result: {:invalid_adapter_result, :ok}
        ] do
      configure(storage: {TraceGuard.TestStorage, mode: mode})
      handler = attach_report_events()
      before = TraceGuard.report_stats()

      # assert_error_sent/2 requires Phoenix to render the 500 *and* re-raise
      # the original exception (it would fail on any other exception).
      id = failing_request()

      assert_receive {:report_event, {:dropped, ^reason}, ^id}
      refute_received {:report_event, :stored, ^id}
      :telemetry.detach(handler)

      after_stats = TraceGuard.report_stats()
      assert after_stats.submitted == before.submitted + 1
      assert after_stats.accepted == before.accepted

      counter = if reason == :overloaded, do: :dropped_overloaded, else: :dropped_other
      assert after_stats[counter] == before[counter] + 1
    end
  end

  test "events emitted while storing never enter any trace" do
    configure(storage: {TraceGuard.TestStorage, mode: :emit_event, max: 3})
    TraceGuard.clear_reports()
    handler = attach_report_events()

    id = failing_request()
    report = fetch_report!(id)

    refute "emitted_by_storage" in query_sources(report)
    # Exactly one report was stored: storing did not trigger another one.
    assert_received {:report_event, :stored, ^id}
    refute_received {:report_event, _, _}
    assert length(TraceGuard.list_reports()) == 1
    :telemetry.detach(handler)
  end

  test "the facade accepts {module, opts} and validates the option" do
    assert_raise ArgumentError, fn -> TraceGuard.Config.validate!(storage: "memory") end
    assert_raise ArgumentError, fn -> TraceGuard.Config.validate!(storage: {Mod, :bad}) end
    assert %{storage: {Mod, [a: 1]}} = TraceGuard.Config.validate!(storage: {Mod, a: 1})
  end
end
