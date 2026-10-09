defmodule TraceGuard.ConcurrencyTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import TraceGuard.TestHelpers

  @endpoint TraceGuard.TestApp.Endpoint

  setup do
    configure(max_reports: 200)
    :ok
  end

  # Each request runs in its own process, like Cowboy/Bandit request
  # processes, and the handlers interleave via random sleeps.
  test "concurrent requests are isolated from each other" do
    requests = for i <- 1..40, do: {"req#{i}", rem(i, 2) == 0}

    results =
      requests
      |> Task.async_stream(
        fn {tag, fail?} ->
          path = "/tagged/#{tag}/#{fail?}"

          if fail? do
            {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), path) end)
            {tag, fail?, trace_id(headers)}
          else
            conn = get(build_conn(), path)
            {tag, fail?, trace_id(conn)}
          end
        end,
        max_concurrency: 40,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    trace_ids = Enum.map(results, &elem(&1, 2))
    assert length(Enum.uniq(trace_ids)) == 40

    for {tag, fail?, trace_id} <- results do
      if fail? do
        report = fetch_report!(trace_id)
        assert report["trace_id"] == trace_id

        sources =
          for %{"name" => "ecto.query"} = e <- report["events"], do: e["metadata"]["source"]

        assert sources == for(i <- 1..5, do: "#{tag}_#{i}")
        assert report["failure"]["message"] == "failure in #{tag}"
        assert report["request"]["route"] == "/tagged/:tag/:fail"
      else
        assert TraceGuard.get_report(trace_id) == {:error, :not_found}
      end
    end

    assert length(TraceGuard.list_reports()) == 20
  end

  # Bandit handles keep-alive requests on one connection in one process.
  test "sequential requests in the same process are correlated separately" do
    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/tagged/first/true") end)
    first = trace_id(headers)

    conn = get(build_conn(), "/tagged/second/false")
    second = trace_id(conn)

    {500, headers, _} = assert_error_sent(500, fn -> get(build_conn(), "/tagged/third/true") end)
    third = trace_id(headers)

    assert TraceGuard.get_report(second) == {:error, :not_found}

    for {id, tag} <- [{first, "first"}, {third, "third"}] do
      report = fetch_report!(id)
      sources = for %{"name" => "ecto.query"} = e <- report["events"], do: e["metadata"]["source"]
      assert Enum.all?(sources, &String.starts_with?(&1, tag))
      assert length(sources) == 5
      assert Enum.count(report["events"], &(&1["name"] == "request.start")) == 1
    end
  end

  test "a request process cannot see another request's in-flight trace" do
    parent = self()

    task =
      Task.async(fn ->
        TraceGuard.Context.start(TraceGuard.Context.generate_trace_id(), %{})
        send(parent, {:started, TraceGuard.current_trace_id()})
        receive do: (:done -> :ok)
      end)

    assert_receive {:started, other_id}
    assert is_binary(other_id)
    assert TraceGuard.current_trace_id() == nil
    assert TraceGuard.get_report(other_id) == {:error, :not_found}

    send(task.pid, :done)
    Task.await(task)
  end
end
