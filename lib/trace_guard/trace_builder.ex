defmodule TraceGuard.TraceBuilder do
  @moduledoc """
  Turns a finished `TraceGuard.Context` into a diagnostic report.

  The pipeline is fixed and runs entirely in the request process when the
  request completes:

    1. **Order** events by observation time, then by sequence number.
    2. **Convert** monotonic timestamps into microsecond offsets from the
       start of the request.
    3. **Sanitize** every value into a JSON-safe term: strings are truncated,
       structs, PIDs, references, functions and tuples are replaced by
       descriptive placeholders, and atom keys become strings.
    4. **Redact** sensitive keys recursively and scrub the exception message.

  Only the result of step 4 ever leaves this module, so nothing unredacted is
  stored or exported. The report structure is documented in
  `docs/architecture.md` and `TraceGuard.report()`.
  """

  alias TraceGuard.{Config, Context, Redactor}

  @schema "traceguard.report/v1"
  @max_depth 8
  @max_list 100

  @base_limitations [
    "Only telemetry events emitted by the request-handling process are included; " <>
      "work performed in other processes (Task, GenServer, etc.) is not correlated.",
    "Individual function calls are not traced; the timeline contains only the Phoenix " <>
      "and Ecto telemetry events listed in the report.",
    "Request bodies, query strings, cookies and SQL parameter values are never captured."
  ]

  @doc """
  Builds a failure description from a caught `kind`/`reason`/`stacktrace`.

  The raw exception is reduced immediately to plain data: module name,
  message, HTTP status mapping and a stacktrace without function arguments.
  Message scrubbing and truncation happen later, in `build/3`.
  """
  @spec failure(atom(), term(), Exception.stacktrace(), String.t(), Config.t()) :: map()
  def failure(_kind, %Plug.Conn.WrapperError{} = wrapper, _stack, source, config) do
    failure(wrapper.kind, wrapper.reason, wrapper.stack, source, config)
  end

  def failure(kind, reason, stacktrace, source, config) do
    normalized = if kind == :error, do: Exception.normalize(:error, reason, stacktrace)

    %{
      kind: Atom.to_string(kind),
      exception: exception_name(normalized),
      message: if(config.capture_exception_message, do: message(kind, normalized, reason)),
      plug_status: if(normalized, do: Plug.Exception.status(normalized)),
      stacktrace: frames(stacktrace, config.max_stacktrace_frames),
      captured_by: source
    }
  end

  defp exception_name(%{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp exception_name(_), do: nil

  # Calls message/1 directly instead of Exception.message/1: when message/1
  # raises, the latter falls back to a string containing the inspected
  # exception struct, which may hold arbitrary data.
  defp message(:error, %module{__exception__: true} = exception, _reason) do
    case module.message(exception) do
      message when is_binary(message) -> message
      _ -> "(message unavailable: message/1 did not return a string)"
    end
  rescue
    _ -> "(message unavailable: message/1 raised)"
  end

  defp message(kind, _normalized, reason) do
    "#{kind}: " <> inspect(reason, limit: 10, printable_limit: 200)
  end

  # Stacktrace entries may carry the actual call arguments instead of an
  # arity (e.g. FunctionClauseError). Arguments are user data, so only their
  # count is kept.
  defp frames(stacktrace, max) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(max)
    |> Enum.map(fn
      {mod, fun, arity_or_args, location} when is_atom(mod) and is_atom(fun) ->
        arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
        file = Keyword.get(location, :file)

        %{
          module: inspect(mod),
          function: "#{fun}/#{arity}",
          file: if(file, do: to_string(file)),
          line: Keyword.get(location, :line),
          application: application_of(mod)
        }

      {fun, arity_or_args, location} when is_function(fun) ->
        arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
        %{module: nil, function: "fn/#{arity}", file: nil, line: Keyword.get(location, :line)}

      _ ->
        %{module: nil, function: "(unknown frame)", file: nil, line: nil}
    end)
  end

  defp frames(_, _), do: []

  defp application_of(mod) do
    case :application.get_application(mod) do
      {:ok, app} -> Atom.to_string(app)
      :undefined -> nil
    end
  end

  @doc """
  Builds the redacted, JSON-safe report for a completed request.

  `status` is the final HTTP status (or nil when unknown).
  """
  @spec build(Context.t(), integer() | nil, Config.t()) :: map()
  def build(%Context{} = ctx, status, %Config{} = config) do
    finished_mono = System.monotonic_time()

    events =
      ctx.events
      |> Enum.sort_by(&{&1.at, &1.seq})
      |> Enum.map(&event_to_map(&1, ctx.started_mono))

    report = %{
      schema: @schema,
      trace_id: ctx.trace_id,
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      outcome: outcome(ctx.failure, status, config),
      request: Map.put(ctx.request, :started_at, DateTime.to_iso8601(ctx.started_at)),
      response: %{status: status},
      duration_us: to_us(finished_mono - ctx.started_mono),
      events: events,
      events_dropped: ctx.dropped,
      failure: ctx.failure,
      limitations: limitations(ctx, status, config)
    }

    report
    |> sanitize(config.max_string_length, 0)
    |> redact(config)
  end

  defp outcome(failure, _status, _config) when is_map(failure), do: "exception"

  defp outcome(nil, status, config) when is_integer(status) and status >= config.failure_status,
    do: "error_status"

  defp outcome(nil, _status, _config), do: "ok"

  defp event_to_map(event, started_mono) do
    %{
      seq: event.seq,
      name: event.name,
      type: event.type,
      offset_us: to_us(event.at - started_mono),
      duration_us: if(event.duration, do: to_us(event.duration)),
      outcome: event.outcome,
      metadata: event.metadata
    }
  end

  defp to_us(native), do: System.convert_time_unit(native, :native, :microsecond)

  defp limitations(ctx, status, config) do
    dynamic = [
      ctx.dropped > 0 &&
        "#{ctx.dropped} event(s) were dropped after max_events (#{config.max_events}) was reached.",
      config.ecto_telemetry_prefixes == [] &&
        "Ecto query events are not captured: no :ecto_telemetry_prefixes are configured.",
      config.ecto_telemetry_prefixes != [] and not config.capture_sql &&
        "SQL text is omitted (capture_sql: false); only query timing, source and outcome are shown.",
      ctx.failure == nil and is_integer(status) &&
        "No exception was observed in the request process; the failure is inferred from " <>
          "the response status #{status}.",
      ctx.failure != nil and ctx.failure.captured_by == "phoenix.error_rendered" &&
        "The exception was raised outside the router (or no router dispatch was observed), " <>
          "so route information and events after the failure point may be missing.",
      not config.capture_exception_message &&
        "The exception message is omitted (capture_exception_message: false)."
    ]

    @base_limitations ++ Enum.filter(dynamic, &is_binary/1)
  end

  ## Sanitization

  defp sanitize(value, max_len, _depth) when is_binary(value), do: sanitize_string(value, max_len)

  defp sanitize(value, _max_len, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize(value, _max_len, _depth) when is_atom(value), do: Atom.to_string(value)

  defp sanitize(_value, _max_len, depth) when depth > @max_depth, do: "(max depth reached)"

  defp sanitize(%{__struct__: module}, _max_len, _depth) when is_atom(module),
    do: "(struct #{inspect(module)})"

  defp sanitize(map, max_len, depth) when is_map(map) do
    Map.new(map, fn {key, value} -> {sanitize_key(key), sanitize(value, max_len, depth + 1)} end)
  end

  defp sanitize(list, max_len, depth) when is_list(list) do
    if List.improper?(list) do
      "(improper list)"
    else
      {kept, rest} = Enum.split(list, @max_list)
      items = Enum.map(kept, &sanitize(&1, max_len, depth + 1))
      if rest == [], do: items, else: items ++ ["(#{length(rest)} more items truncated)"]
    end
  end

  defp sanitize(value, _max_len, _depth) when is_tuple(value), do: "(tuple)"
  defp sanitize(value, _max_len, _depth) when is_pid(value), do: "(pid)"
  defp sanitize(value, _max_len, _depth) when is_reference(value), do: "(reference)"
  defp sanitize(value, _max_len, _depth) when is_function(value), do: "(function)"
  defp sanitize(value, _max_len, _depth) when is_port(value), do: "(port)"
  defp sanitize(_value, _max_len, _depth), do: "(unsupported term)"

  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key) when is_integer(key), do: Integer.to_string(key)
  defp sanitize_key(_key), do: "(unsupported key)"

  defp sanitize_string(value, max_len) do
    cond do
      not String.valid?(value) -> "(binary, #{byte_size(value)} bytes)"
      String.length(value) > max_len -> String.slice(value, 0, max_len) <> "…(truncated)"
      true -> value
    end
  end

  ## Redaction

  defp redact(report, config) do
    keys = config.redact_keys
    {report, key_count} = Redactor.redact(report, keys)

    {failure, scrub_count} =
      case report do
        %{"failure" => %{"message" => message} = failure} when is_binary(message) ->
          {scrubbed, count} = Redactor.scrub_string(message, keys)
          {%{failure | "message" => scrubbed}, count}

        %{"failure" => failure} ->
          {failure, 0}
      end

    Map.merge(report, %{
      "failure" => failure,
      "redaction" => %{
        "applied" => true,
        "placeholder" => Redactor.placeholder(),
        "sensitive_keys" => keys,
        "redacted_values" => key_count,
        "scrubbed_message_values" => scrub_count
      }
    })
  end
end
