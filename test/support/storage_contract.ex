defmodule TraceGuard.StorageContract do
  @moduledoc false
  # Contract tests every TraceGuard.Storage adapter must pass, exercised
  # through the TraceGuard.Storage facade and the public API.
  #
  #     use TraceGuard.StorageContract, storage: TraceGuard.ReportStore
  #
  # An optional `setup:` block runs after the adapter is configured (e.g. to
  # start the adapter's process with a fresh database).
  #
  # The adapter must retain at most 3 reports for these tests (configured
  # through :max_reports, or the adapter's own :max option).

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: false

      import TraceGuard.TestHelpers

      @moduletag unquote(opts[:moduletag] || [])

      @storage unquote(opts[:storage])

      setup do
        configure(storage: @storage, max_reports: 3)
        unquote(opts[:setup])
        TraceGuard.clear_reports()
        :ok
      end

      defp report(i, extra \\ %{}) do
        Map.merge(
          %{
            "trace_id" => TraceGuard.Context.generate_trace_id(),
            "generated_at" => "2026-10-10T00:00:0#{i}Z",
            "outcome" => "exception",
            "request" => %{
              "method" => "GET",
              "route" => "/r/#{i}",
              "request_id" => "req-#{i}",
              "incoming_id" => %{"header" => "x-correlation-id", "value" => "corr-#{i}"}
            },
            "response" => %{"status" => 500},
            "failure" => %{"kind" => "error", "exception" => "E#{i}", "captured_by" => "test"}
          },
          extra
        )
      end

      defp submit!(report) do
        assert {:ok, accepted} = TraceGuard.Storage.put(report)
        assert accepted in [:stored, :queued]
        assert {:ok, ^report} = TraceGuard.await_report(report["trace_id"], 1_000)
        report
      end

      test "an accepted report becomes retrievable by its trace ID, unchanged" do
        r = submit!(report(1))
        assert TraceGuard.get_report(r["trace_id"]) == {:ok, r}

        assert TraceGuard.get_report(TraceGuard.Context.generate_trace_id()) ==
                 {:error, :not_found}
      end

      test "list returns documented summaries, newest first" do
        [a, b] = Enum.map(1..2, &submit!(report(&1)))

        assert [%{"trace_id" => id_b} = sb, %{"trace_id" => id_a}] = TraceGuard.list_reports()
        assert {id_a, id_b} == {a["trace_id"], b["trace_id"]}

        assert sb == %{
                 "trace_id" => id_b,
                 "generated_at" => "2026-10-10T00:00:02Z",
                 "outcome" => "exception",
                 "method" => "GET",
                 "route" => "/r/2",
                 "status" => 500,
                 "kind" => "error",
                 "exception" => "E2",
                 "captured_by" => "test",
                 "request_id" => "req-2",
                 "incoming_id" => "corr-2"
               }
      end

      test "retention is bounded and evicts the oldest" do
        reports = Enum.map(1..5, &submit!(report(&1)))
        retained = Enum.map(TraceGuard.list_reports(), & &1["trace_id"])

        assert retained ==
                 reports |> Enum.take(-3) |> Enum.reverse() |> Enum.map(& &1["trace_id"])

        assert TraceGuard.get_report(hd(reports)["trace_id"]) == {:error, :not_found}
      end

      test "delete and clear remove reports" do
        [a, b] = Enum.map(1..2, &submit!(report(&1)))
        assert :ok = TraceGuard.delete_report(a["trace_id"])
        assert TraceGuard.get_report(a["trace_id"]) == {:error, :not_found}
        assert {:ok, _} = TraceGuard.get_report(b["trace_id"])

        assert :ok = TraceGuard.clear_reports()
        assert TraceGuard.list_reports() == []
      end

      test "every accepted report is announced exactly once as stored" do
        handler = attach_report_events()
        r = submit!(report(1))
        id = r["trace_id"]

        assert_receive {:report_event, :stored, ^id}
        refute_receive {:report_event, _, ^id}, 50
        :telemetry.detach(handler)
      end

      test "stats is a map that names the adapter" do
        assert %{adapter: _} = TraceGuard.report_stats()
      end
    end
  end
end
