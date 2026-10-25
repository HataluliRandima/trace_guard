defmodule TraceGuard.TraceBuilder do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Turns a finished `TraceGuard.Context` into a diagnostic report.

  The pipeline is fixed and runs entirely in the request process when the
  request completes:

    1. **Order** events by time (see "Timestamps" in
       `TraceGuard.EventCollector`), then by sequence number.
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
    "Only telemetry events emitted by the request-handling process, or by functions " <>
      "wrapped with TraceGuard.wrap/1, are included; work in other processes " <>
      "(plain Task, GenServer, etc.) is not correlated.",
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
    {exception, message} = describe(kind, normalized || reason)

    %{
      kind: Atom.to_string(kind),
      exception: exception,
      message: if(config.capture_exception_message, do: message),
      plug_status: if(normalized, do: Plug.Exception.status(normalized)),
      stacktrace: frames(stacktrace, config.max_stacktrace_frames),
      captured_by: source
    }
  end

  # Returns {exception module name | nil, message}. Arbitrary terms (thrown
  # values, exit reasons, exception structs) are never inspected: they can
  # hold any application data. Only exception messages are kept, and they are
  # scrubbed later like every other message.
  defp describe(:error, %{__exception__: true} = exception),
    do: {exception_name(exception), exception_message(exception)}

  defp describe(:exit, reason), do: describe_exit(reason)

  defp describe(:throw, value),
    do: {nil, "throw of a #{type_of(value)} value (value not captured)"}

  # e.g. Task.await/2 exits with {reason, {Task, :await, [task, timeout]}}.
  defp describe_exit({reason, {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args) do
    {exception, message} = describe_exit(reason)
    {exception, "#{module_name(module)}.#{function}/#{length(args)} exited: #{message}"}
  end

  # A crashed process: {exception, stacktrace}.
  defp describe_exit({%{__exception__: true} = exception, stacktrace}) when is_list(stacktrace),
    do: {exception_name(exception), "process crashed: " <> exception_message(exception)}

  defp describe_exit(reason) when is_atom(reason), do: {nil, "exit: #{inspect(reason)}"}

  defp describe_exit({:shutdown, _}), do: {nil, "exit: {:shutdown, _} (details not captured)"}

  defp describe_exit(reason),
    do: {nil, "exit with a #{type_of(reason)} reason (reason not captured)"}

  defp type_of(value) when is_map(value) and is_map_key(value, :__struct__), do: "struct"
  defp type_of(value) when is_map(value), do: "map"
  defp type_of(value) when is_tuple(value), do: "#{tuple_size(value)}-tuple"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(value) when is_number(value), do: "number"
  defp type_of(_value), do: "term"

  defp exception_name(%module{}), do: module_name(module)

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      _ -> inspect(module)
    end
  end

  # Calls message/1 directly instead of Exception.message/1: when message/1
  # raises, the latter falls back to a string containing the inspected
  # exception struct, which may hold arbitrary data.
  defp exception_message(%module{} = exception) do
    case module.message(exception) do
      message when is_binary(message) -> message
      _ -> "(message unavailable: message/1 did not return a string)"
    end
  rescue
    _ -> "(message unavailable: message/1 raised)"
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

  # :application.get_application/1 scans the application controller's table
  # on every call (~20 µs per frame when profiled). A module -> application
  # index is built once, on the first failure, from the applications loaded
  # at that moment. Modules of applications loaded later map to nil.
  defp application_of(mod) do
    index =
      case :persistent_term.get({__MODULE__, :application_index}, nil) do
        nil -> build_application_index()
        index -> index
      end

    case index do
      %{^mod => app} -> Atom.to_string(app)
      _ -> nil
    end
  end

  defp build_application_index do
    index =
      for {app, _description, _vsn} <- :application.loaded_applications(),
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules,
          into: %{},
          do: {module, app}

    :persistent_term.put({__MODULE__, :application_index}, index)
    index
  end

  @doc """
  Builds the redacted, JSON-safe report for a completed request.

  `status` is the final HTTP status (or nil when unknown).
  """
  @spec build(Context.t(), integer() | nil, Config.t()) :: map()
  def build(%Context{} = ctx, status, %Config{} = config) do
    finished_mono = System.monotonic_time()

    # Events from different processes are ordered by monotonic time (one
    # clock per node); ties keep request events first, then per-process
    # order. `seq` is then renumbered as the position in the timeline.
    events =
      ctx.events
      |> Enum.sort_by(&{&1.at, process_rank(&1), &1.seq})
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> event_to_map(%{event | seq: seq}, ctx.started_mono) end)

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
      tasks: task_summary(ctx.tasks),
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

  defp process_rank(%{process: "request"}), do: 0
  defp process_rank(_event), do: 1

  defp task_summary(%{status: _} = summary), do: summary
  defp task_summary(_no_propagation), do: nil

  defp event_to_map(event, started_mono) do
    %{
      seq: event.seq,
      process: Map.get(event, :process, "request"),
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
        "The exception message is omitted (capture_exception_message: false).",
      task_limitation(ctx.tasks, config)
    ]

    @base_limitations ++ Enum.filter(dynamic, &is_binary/1)
  end

  defp task_limitation(%{status: "complete"}, _config),
    do:
      "Task events are included only if they reached TraceGuard before the request " <>
        "completed; work still running at that point is not shown."

  defp task_limitation(%{status: "timeout"}, config),
    do:
      "Task events could not be collected within task_drain_timeout " <>
        "(#{config.task_drain_timeout} ms) and are missing."

  defp task_limitation(%{status: "unavailable"}, _config),
    do: "The task collector had already stopped; task events are missing."

  defp task_limitation(%{status: "collector_limit_reached"}, config),
    do:
      "Task propagation was skipped because max_task_collectors " <>
        "(#{config.max_task_collectors}) was reached; task events are missing."

  defp task_limitation(_tasks, _config), do: nil

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
      # A string cannot have more graphemes than bytes: skip counting.
      byte_size(value) <= max_len -> value
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
