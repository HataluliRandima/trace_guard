defmodule TraceGuard.TestApp do
  @moduledoc false
  # A minimal, real Phoenix endpoint + router used to exercise TraceGuard
  # against Phoenix's actual error-handling lifecycle.
  #
  # Ecto is not a dependency of the library, so query events here are
  # emitted with `:telemetry.execute/3` using the same event name and
  # metadata shape as Ecto.Adapters.SQL (ecto_sql 3.14). Real Ecto queries are
  # exercised end-to-end in the demo application's test suite.

  def emit_query(source, opts \\ []) do
    :telemetry.execute(
      [:test_app, :repo, :query],
      %{
        query_time: System.convert_time_unit(150, :microsecond, :native),
        queue_time: System.convert_time_unit(20, :microsecond, :native),
        decode_time: System.convert_time_unit(5, :microsecond, :native),
        total_time: System.convert_time_unit(175, :microsecond, :native)
      },
      %{
        type: :ecto_sql_query,
        repo: TraceGuard.TestApp.Repo,
        result: Keyword.get(opts, :result, {:ok, %{num_rows: 1, rows: [["alice@example.com"]]}}),
        params: ["super-secret-param"],
        cast_params: ["super-secret-param"],
        query: ~s{SELECT u0."email" FROM "#{source}" AS u0 WHERE (u0."password" = ?)},
        source: source,
        stacktrace: [
          {Ecto.Repo.Supervisor, :tuplet, 2, [file: ~c"lib/ecto/repo/supervisor.ex", line: 1]},
          {TraceGuard.TestApp.Controller, :crash, 2,
           [file: ~c"test/support/test_app.ex", line: 42]}
        ],
        options: [secret_option: "do-not-leak"]
      }
    )
  end
end

defmodule TraceGuard.TestApp.Repo do
  @moduledoc false
end

defmodule TraceGuard.TestApp.BoomError do
  defexception [:message]
end

defmodule TraceGuard.TestApp.NotFoundError do
  defexception message: "record not found", plug_status: 404
end

defmodule TraceGuard.TestApp.ErrorJSON do
  @moduledoc false
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

defmodule TraceGuard.TestApp.Controller do
  use Phoenix.Controller, formats: [:json]

  alias TraceGuard.TestApp

  def ok(conn, _params) do
    TestApp.emit_query("users")
    json(conn, %{ok: true, trace_id: TraceGuard.current_trace_id()})
  end

  def crash(conn, _params) do
    TestApp.emit_query("users")
    TestApp.emit_query("orders", result: {:error, %RuntimeError{message: "db said no"}})

    raise TestApp.BoomError,
      message: "payment gateway rejected api_key=fake_gateway_key_123 for user 42"

    conn
  end

  def throw_value(_conn, _params), do: throw(%{password: "hunter2", reason: :nope})

  def not_found(_conn, _params), do: raise(TestApp.NotFoundError)

  def unavailable(conn, _params) do
    TestApp.emit_query("inventory")
    send_resp(conn, 503, "unavailable")
  end

  def many(conn, %{"n" => n}) do
    for i <- 1..String.to_integer(n), do: TestApp.emit_query("t#{i}")
    send_resp(conn, 500, "too many")
  end

  # Used by the concurrency tests: tags every query with the request's tag
  # and interleaves with other requests via short sleeps.
  def tagged(conn, %{"tag" => tag, "fail" => fail}) do
    for i <- 1..5 do
      TestApp.emit_query("#{tag}_#{i}")
      Process.sleep(:rand.uniform(3))
    end

    if fail == "true", do: raise(TestApp.BoomError, message: "failure in #{tag}")
    json(conn, %{tag: tag, trace_id: TraceGuard.current_trace_id()})
  end

  def spawn_query(conn, _params) do
    # Work in another process is not correlated (documented limitation).
    Task.async(fn -> TestApp.emit_query("from_task") end) |> Task.await()
    TestApp.emit_query("from_request")
    send_resp(conn, 500, "spawned")
  end

  ## Task propagation

  # Two wrapped tasks and one unwrapped task, all awaited.
  def tasks_await(conn, %{"tag" => tag, "fail" => fail}) do
    wrapped =
      for suffix <- ["a", "b"] do
        Task.async(TraceGuard.wrap(fn -> TestApp.emit_query("#{tag}_task_#{suffix}") end))
      end

    unwrapped = Task.async(fn -> TestApp.emit_query("#{tag}_unwrapped") end)
    Task.await_many([unwrapped | wrapped])
    TestApp.emit_query("#{tag}_request")

    if fail == "true", do: raise(TestApp.BoomError, message: "tasks failed in #{tag}")
    json(conn, %{tag: tag})
  end

  # A wrapped task that wraps again for a grandchild.
  def tasks_nested(conn, _params) do
    Task.async(
      TraceGuard.wrap(fn ->
        TestApp.emit_query("child")
        Task.async(TraceGuard.wrap(fn -> TestApp.emit_query("grandchild") end)) |> Task.await()
      end)
    )
    |> Task.await()

    send_resp(conn, 500, "nested")
  end

  # Repeated wrap calls and an arity-1 wrapped function in async_stream.
  def tasks_repeated(conn, _params) do
    first = Task.async(TraceGuard.wrap(fn -> TestApp.emit_query("first") end))
    second = Task.async(TraceGuard.wrap(fn -> TestApp.emit_query("second") end))
    Task.await_many([first, second])

    ["s1", "s2", "s3"]
    |> Task.async_stream(TraceGuard.wrap(fn source -> TestApp.emit_query(source) end))
    |> Stream.run()

    send_resp(conn, 500, "repeated")
  end

  # The child raises under an unlinked supervisor; awaiting it exits the
  # request process, which Phoenix renders as a 500.
  def tasks_child_fails(_conn, _params) do
    TraceGuard.TestApp.TaskSup
    |> Task.Supervisor.async_nolink(
      TraceGuard.wrap(fn ->
        TestApp.emit_query("before_child_failure")
        raise TestApp.BoomError, message: "child failed with token=abc123"
      end)
    )
    |> Task.await()
  end

  # Fire-and-forget task that only proceeds when the test says so, i.e.
  # after this request has completed.
  def tasks_late(conn, _params) do
    test_pid = self()

    Task.start(
      TraceGuard.wrap(fn ->
        send(test_pid, {:late_child_ready, self()})

        receive do
          :go -> TestApp.emit_query("late_child")
        end

        send(test_pid, :late_child_done)
      end)
    )

    receive do
      {:late_child_ready, child} -> send(test_pid, {:late_child, child})
    end

    TestApp.emit_query("request_before_late_child")
    send_resp(conn, 500, "responded before the child ran")
  end

  def tasks_flood(conn, %{"n" => n}) do
    n = String.to_integer(n)

    1..4
    |> Enum.map(fn worker ->
      Task.async(
        TraceGuard.wrap(fn -> for i <- 1..n, do: TestApp.emit_query("w#{worker}_#{i}") end)
      )
    end)
    |> Task.await_many()

    send_resp(conn, 500, "flooded")
  end

  def tasks_ok(conn, _params) do
    Task.async(TraceGuard.wrap(fn -> TestApp.emit_query("ok_task") end)) |> Task.await()
    json(conn, %{ok: true})
  end

  def send_then_crash(conn, _params) do
    conn = send_resp(conn, 200, "sent")
    raise TestApp.BoomError, message: "after send"
    conn
  end
end

defmodule TraceGuard.TestApp.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TraceGuard.TestApp do
    pipe_through :api

    get "/ok", Controller, :ok
    get "/crash", Controller, :crash
    get "/throw", Controller, :throw_value
    get "/missing", Controller, :not_found
    get "/unavailable", Controller, :unavailable
    get "/many/:n", Controller, :many
    get "/tagged/:tag/:fail", Controller, :tagged
    get "/spawn", Controller, :spawn_query
    get "/send_then_crash", Controller, :send_then_crash
    get "/users/:id", Controller, :ok
    get "/tasks/await/:tag/:fail", Controller, :tasks_await
    get "/tasks/nested", Controller, :tasks_nested
    get "/tasks/repeated", Controller, :tasks_repeated
    get "/tasks/child_fails", Controller, :tasks_child_fails
    get "/tasks/late", Controller, :tasks_late
    get "/tasks/flood/:n", Controller, :tasks_flood
    get "/tasks/ok", Controller, :tasks_ok
  end
end

defmodule TraceGuard.TestApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :trace_guard

  plug Plug.RequestId
  plug TraceGuard.Plug
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug :maybe_crash_in_endpoint
  plug TraceGuard.TestApp.Router

  # Simulates a failure in an endpoint plug, i.e. outside the router.
  defp maybe_crash_in_endpoint(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-test-endpoint-crash") do
      [] -> conn
      _ -> raise TraceGuard.TestApp.BoomError, message: "endpoint plug failed"
    end
  end
end

defmodule TraceGuard.TestApp.DebugEndpoint do
  # Same app with `debug_errors: true` (the Phoenix dev default), which adds
  # Plug.Debugger in front of Phoenix's error rendering.
  use Phoenix.Endpoint, otp_app: :trace_guard

  plug Plug.RequestId
  plug TraceGuard.Plug
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug :maybe_crash_in_endpoint
  plug TraceGuard.TestApp.Router

  defp maybe_crash_in_endpoint(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-test-endpoint-crash") do
      [] -> conn
      _ -> raise TraceGuard.TestApp.BoomError, message: "endpoint plug failed"
    end
  end
end
