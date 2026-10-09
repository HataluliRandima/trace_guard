defmodule TraceGuard.TraceBuilderTest do
  use ExUnit.Case, async: true

  alias TraceGuard.{Config, Context, TraceBuilder}

  defmodule CardError do
    defexception [:message, :card_number]
  end

  defmodule BadMessage do
    defexception [:password]
    def message(_), do: raise("nope")
  end

  defp config(opts \\ []), do: Config.validate!(opts)

  defp ctx_with(metadata) do
    ctx = %Context{
      trace_id: Context.generate_trace_id(),
      started_mono: System.monotonic_time(),
      started_at: DateTime.utc_now(),
      request: %{method: "POST", headers: %{"authorization" => "Bearer x"}}
    }

    event = %{
      seq: 1,
      name: "custom",
      type: "custom",
      at: ctx.started_mono,
      duration: nil,
      outcome: nil,
      metadata: metadata
    }

    %{ctx | events: [event], seq: 1, retained: 1}
  end

  test "reports contain only JSON-safe values" do
    metadata = %{
      pid: self(),
      ref: make_ref(),
      fun: fn -> :ok end,
      tuple: {:a, 1},
      struct: %URI{host: "example.com"},
      atom: :value,
      binary: <<255, 0, 1>>,
      long: String.duplicate("x", 2_000),
      list: Enum.to_list(1..150),
      improper: [1 | 2],
      nested: %{{:tuple, :key} => 1, 5 => "int key"}
    }

    report = TraceBuilder.build(ctx_with(metadata), 500, config())
    meta = hd(report["events"])["metadata"]

    assert meta["pid"] == "(pid)"
    assert meta["ref"] == "(reference)"
    assert meta["fun"] == "(function)"
    assert meta["tuple"] == "(tuple)"
    assert meta["struct"] == "(struct URI)"
    assert meta["atom"] == "value"
    assert meta["binary"] == "(binary, 3 bytes)"
    assert String.length(meta["long"]) < 600
    assert length(meta["list"]) == 101
    assert meta["improper"] == "(improper list)"
    assert meta["nested"] == %{"(unsupported key)" => 1, "5" => "int key"}

    assert {:ok, json} = Jason.encode(report)
    assert Jason.decode!(json) == report
  end

  test "redaction is applied before the report is returned" do
    report = TraceBuilder.build(ctx_with(%{"token" => "abc", "safe" => 1}), 500, config())

    assert hd(report["events"])["metadata"] == %{"token" => "[REDACTED]", "safe" => 1}
    assert report["request"]["headers"] == %{"authorization" => "[REDACTED]"}
    assert report["redaction"]["applied"] == true
    assert report["redaction"]["redacted_values"] == 2
    refute Jason.encode!(report) =~ "Bearer x"
  end

  describe "failure/5" do
    test "keeps the exception type and message but never stacktrace arguments" do
      stack = [
        {MyApp.Billing, :charge, [%{card: "4242", password: "pw"}],
         [file: ~c"lib/billing.ex", line: 7]},
        {MyApp.Billing, :run, 1, [file: ~c"lib/billing.ex", line: 3]}
      ]

      failure =
        TraceBuilder.failure(:error, %ArgumentError{message: "bad"}, stack, "src", config())

      assert failure.kind == "error"
      assert failure.exception == "ArgumentError"
      assert failure.message == "bad"
      assert failure.plug_status == 500

      assert [%{function: "charge/1", line: 7, file: "lib/billing.ex"}, %{function: "run/1"}] =
               failure.stacktrace

      refute inspect(failure) =~ "4242"
    end

    test "normalizes Erlang errors and unwraps Plug.Conn.WrapperError" do
      failure = TraceBuilder.failure(:error, :badarg, [], "src", config())
      assert failure.exception == "ArgumentError"

      wrapper = %Plug.Conn.WrapperError{
        conn: nil,
        kind: :error,
        reason: %RuntimeError{message: "inner"},
        stack: []
      }

      assert %{exception: "RuntimeError", message: "inner"} =
               TraceBuilder.failure(:error, wrapper, [], "src", config())
    end

    test "message capture can be disabled" do
      failure =
        TraceBuilder.failure(
          :error,
          %RuntimeError{message: "pii"},
          [],
          "src",
          config(capture_exception_message: false)
        )

      assert failure.message == nil
    end

    test "survives exceptions whose message/1 raises" do
      failure = TraceBuilder.failure(:error, %BadMessage{password: "pw-123"}, [], "src", config())
      assert failure.message == "(message unavailable: message/1 raised)"
    end

    test "exit and throw reasons are described, never inspected" do
      crash = %CardError{message: "card declined", card_number: "4242424242424242"}
      stack = [{M, :f, 1, []}]
      task = %{pid: self(), owner: self(), password: "pw"}

      cases = [
        # Task.await/2 on a crashed task
        {:exit, {{crash, stack}, {Task, :await, [task, 5000]}},
         "TraceGuard.TraceBuilderTest.CardError",
         "Task.await/2 exited: process crashed: card declined"},
        {:exit, {crash, stack}, "TraceGuard.TraceBuilderTest.CardError",
         "process crashed: card declined"},
        {:exit, :timeout, nil, "exit: :timeout"},
        {:exit, {:shutdown, %{password: "pw"}}, nil,
         "exit: {:shutdown, _} (details not captured)"},
        {:exit, %{card_number: "4242424242424242"}, nil,
         "exit with a map reason (reason not captured)"},
        {:throw, %{password: "pw"}, nil, "throw of a map value (value not captured)"}
      ]

      for {kind, reason, exception, message} <- cases do
        failure = TraceBuilder.failure(kind, reason, [], "src", config())
        assert failure.exception == exception
        assert failure.message == message
        refute inspect(failure) =~ "4242"
        refute inspect(failure) =~ "pw"
      end
    end

    test "limits stacktrace frames" do
      stack = for i <- 1..50, do: {M, :f, i, []}

      failure =
        TraceBuilder.failure(
          :error,
          %RuntimeError{},
          stack,
          "src",
          config(max_stacktrace_frames: 5)
        )

      assert length(failure.stacktrace) == 5
    end
  end
end
