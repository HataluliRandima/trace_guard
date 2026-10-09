defmodule TraceGuard.Plug do
  @moduledoc """
  Starts a TraceGuard trace for each request.

  Add it to your endpoint **after** `Plug.RequestId` (so the request ID can be
  recorded) and **before** `Plug.Telemetry` and your router:

      plug Plug.RequestId
      plug TraceGuard.Plug
      plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
      ...
      plug MyAppWeb.Router

  ## What it does

  * Generates a fresh 128-bit trace ID and stores a request context in the
    current process (see `TraceGuard.Context`).
  * Records method, start time, allow-listed request headers, the
    `x-request-id` set by `Plug.RequestId` and, when configured, a
    validated incoming correlation ID and the request path. Query strings,
    bodies and cookies are never read.
  * Adds `trace_guard_id` to `Logger` metadata and, by default, an
    `x-traceguard-id` response header.
  * Registers a `before_send` callback that records the response status and
    completes the trace.

  ## What it does not do

  A plain Plug **cannot** observe exceptions raised by downstream plugs: it
  returns its conn before the router runs. Exceptions are therefore captured
  through Phoenix telemetry (`[:phoenix, :router_dispatch, :exception]` and
  `[:phoenix, :error_rendered]`) by `TraceGuard.Telemetry`. This plug never
  rescues, so your application's error handling is unchanged.
  """

  @behaviour Plug

  import Plug.Conn

  alias TraceGuard.{Config, Context, EventCollector}

  @incoming_id ~r/\A[A-Za-z0-9._:\-]{1,128}\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Config.get()
    if config.enabled, do: start_trace(conn, config), else: conn
  end

  defp start_trace(conn, config) do
    trace_id = Context.generate_trace_id()
    Context.start(trace_id, request_metadata(conn, config))
    EventCollector.record("request.start", "request", %{}, lifecycle: true)
    Logger.metadata(trace_guard_id: trace_id)

    conn
    |> put_private(:trace_guard_id, trace_id)
    |> maybe_put_response_header(config.response_header, trace_id)
    |> register_before_send(&before_send(&1, trace_id))
  end

  defp request_metadata(conn, config) do
    %{
      method: conn.method,
      route: nil,
      path: if(config.capture_path, do: conn.request_path),
      request_id: conn |> get_resp_header("x-request-id") |> List.first(),
      incoming_id: incoming_id(conn, config.incoming_header),
      headers: captured_headers(conn, config.capture_request_headers)
    }
  end

  # External IDs are untrusted. They are recorded separately from the
  # internally generated trace ID, only if they match a strict format, and
  # are never used as a key into the report store.
  defp incoming_id(_conn, nil), do: nil

  defp incoming_id(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> if value =~ @incoming_id, do: %{header: header, value: value}
      [] -> nil
    end
  end

  defp captured_headers(_conn, []), do: %{}

  defp captured_headers(conn, allowed) do
    for {name, value} <- conn.req_headers, name in allowed, into: %{}, do: {name, value}
  end

  defp maybe_put_response_header(conn, nil, _trace_id), do: conn

  defp maybe_put_response_header(conn, header, trace_id),
    do: put_resp_header(conn, header, trace_id)

  # Runs in the request process just before the response is sent, including
  # when Phoenix renders an error page for an exception raised inside the
  # router. Never raises: a TraceGuard bug must not break the response.
  defp before_send(conn, trace_id) do
    case Context.current() do
      %{trace_id: ^trace_id} ->
        EventCollector.record("request.stop", "request", %{status: conn.status},
          lifecycle: true,
          outcome: if(conn.status >= Config.get().failure_status, do: "error", else: "ok")
        )

        EventCollector.finish(conn.status)

      _ ->
        :ok
    end

    conn
  rescue
    exception ->
      TraceGuard.Telemetry.log_internal_error(exception, __STACKTRACE__)
      conn
  end
end
