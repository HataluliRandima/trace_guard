defmodule TraceGuard.ContextTest do
  use ExUnit.Case, async: true

  alias TraceGuard.Context

  describe "generate_trace_id/0" do
    test "produces 32 lowercase hex characters" do
      id = Context.generate_trace_id()
      assert id =~ ~r/\A[0-9a-f]{32}\z/
      assert Context.valid_trace_id?(id)
    end

    test "is unique across many generations and processes" do
      ids =
        1..20
        |> Task.async_stream(fn _ -> for _ <- 1..500, do: Context.generate_trace_id() end)
        |> Enum.flat_map(fn {:ok, ids} -> ids end)

      assert length(ids) == 10_000
      assert ids |> Enum.uniq() |> length() == 10_000
    end
  end

  test "valid_trace_id?/1 rejects anything that is not a TraceGuard ID" do
    for bad <- [
          nil,
          "",
          "abc",
          String.duplicate("A", 32),
          String.duplicate("g", 32),
          "../etc/passwd",
          123
        ] do
      refute Context.valid_trace_id?(bad)
    end
  end

  test "context is local to the calling process" do
    ctx = Context.start(Context.generate_trace_id(), %{})
    assert Context.current() == ctx

    other = Task.async(fn -> Context.current() end) |> Task.await()
    assert other == nil

    assert Context.take() == ctx
    assert Context.current() == nil
  end

  test "start/2 replaces a stale context in a reused process" do
    first = Context.start(Context.generate_trace_id(), %{n: 1})
    second = Context.start(Context.generate_trace_id(), %{n: 2})

    assert first.trace_id != second.trace_id
    assert Context.current().request == %{n: 2}
    Context.take()
  end
end
