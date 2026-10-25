defmodule TraceGuard.Telemetry do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Attaches TraceGuard's handlers to selected `:telemetry` events.

  | Telemetry event                              | Timeline event                    |
  | -------------------------------------------- | --------------------------------- |
  | `[:phoenix, :endpoint, :start]`              | `phoenix.endpoint.start`          |
  | `[:phoenix, :endpoint, :stop]`               | `phoenix.endpoint.stop`           |
  | `[:phoenix, :router_dispatch, :start]`       | `phoenix.router_dispatch.start`   |
  | `[:phoenix, :router_dispatch, :stop]`        | `phoenix.router_dispatch.stop`    |
  | `[:phoenix, :router_dispatch, :exception]`   | `phoenix.router_dispatch.exception` + failure |
  | `[:phoenix, :error_rendered]`                | `phoenix.error_rendered` + failure (fallback) |
  | `prefix ++ [:query]` per configured Ecto repo | `ecto.query`                     |

  ## Metadata filtering

  Telemetry metadata routinely contains the whole `Plug.Conn`, Ecto query
  parameters, results and options. Handlers never store metadata maps
  wholesale: each handler copies an explicit allow-list of fields, converted
  to plain strings and numbers.

  ## Safety

  Handlers run synchronously in the emitting (request) process. They only
  touch that process's dictionary, do no I/O, and rescue every error;
  `:telemetry` permanently detaches handlers that raise, which would silently
  disable tracing.
  """

  require Logger

  alias TraceGuard.{Config, EventCollector, TraceBuilder}

  @handler_id {__MODULE__, :handlers}

  @phoenix_events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :start],
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :router_dispatch, :exception],
    [:phoenix, :error_rendered]
  ]

  @doc "The telemetry events TraceGuard attaches to for the given configuration."
  @spec events(Config.t()) :: [[atom()]]
  def events(%Config{} = config) do
    @phoenix_events ++ Enum.map(config.ecto_telemetry_prefixes, &(&1 ++ [:query]))
  end

  @doc """
  Attaches (or re-attaches) the handlers for the current configuration.

  Idempotent and safe to call concurrently: detach + attach is not atomic in
  `:telemetry`, so callers are serialized with a node-local lock.
  """
  @spec attach() :: :ok
  def attach do
    :global.trans({{__MODULE__, :attach}, self()}, &do_attach/0, [node()])
  end

  defp do_attach do
    detach()
    config = Config.get()

    if config.enabled do
      :ok = :telemetry.attach_many(@handler_id, events(config), &__MODULE__.handle_event/4, nil)
    end

    :ok
  end

  @doc "Detaches TraceGuard's handlers."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    handle(event, measurements, metadata)
  rescue
    exception -> log_internal_error(exception, __STACKTRACE__)
  end

  @doc false
  def log_internal_error(exception, stacktrace) do
    Logger.warning(
      "TraceGuard ignored an internal error: " <> Exception.format(:error, exception, stacktrace)
    )

    :ok
  end

  ## Phoenix endpoint

  defp handle([:phoenix, :endpoint, :start], _measurements, _metadata) do
    EventCollector.record("phoenix.endpoint.start", "endpoint", %{}, span: {:start, :endpoint})
  end

  defp handle([:phoenix, :endpoint, :stop], measurements, %{conn: conn}) do
    EventCollector.record("phoenix.endpoint.stop", "endpoint", %{status: conn.status},
      duration: measurements[:duration],
      span: {:stop, :endpoint}
    )
  end

  ## Phoenix router

  defp handle([:phoenix, :router_dispatch, :start], _measurements, metadata) do
    config = Config.get()
    route = metadata[:route]

    fields = %{route: route}

    fields =
      if config.capture_path_params,
        do: Map.put(fields, :path_params, metadata[:path_params] || %{}),
        else: fields

    EventCollector.put_request_fields(fields)

    EventCollector.record("phoenix.router_dispatch.start", "router", route_metadata(metadata),
      span: {:start, :router_dispatch}
    )
  end

  defp handle([:phoenix, :router_dispatch, :stop], measurements, metadata) do
    status = metadata[:conn] && metadata.conn.status

    EventCollector.record(
      "phoenix.router_dispatch.stop",
      "router",
      Map.put(route_metadata(metadata), :status, status),
      duration: measurements[:duration],
      outcome: "ok",
      span: {:stop, :router_dispatch}
    )
  end

  defp handle([:phoenix, :router_dispatch, :exception], measurements, metadata) do
    %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata

    failure =
      TraceBuilder.failure(
        kind,
        reason,
        stacktrace,
        "phoenix.router_dispatch.exception",
        Config.get()
      )

    EventCollector.record(
      "phoenix.router_dispatch.exception",
      "exception",
      route_metadata(metadata) |> Map.merge(%{kind: failure.kind, exception: failure.exception}),
      duration: measurements[:duration],
      outcome: "error",
      lifecycle: true,
      span: {:stop, :router_dispatch}
    )

    EventCollector.put_failure(failure)
    complete_unwrapped(kind)
  end

  ## Phoenix error rendering
  #
  # Phoenix.Endpoint.RenderErrors sends the error response *before* emitting
  # this event. For exceptions raised inside the router, the trace is already
  # complete (TraceGuard.Plug's before_send for :error; the router exception
  # handler above for throw/exit), so there is no context left here. This
  # handler only acts when the exception was raised outside the router (e.g.
  # in an endpoint plug after TraceGuard.Plug). It runs after the response
  # was sent, so under Cowboy, which terminates the request process once the
  # response is complete, it may not get to finish (documented limitation).

  defp handle([:phoenix, :error_rendered], _measurements, metadata) do
    %{kind: kind, reason: reason, stacktrace: stacktrace, status: status} = metadata

    failure =
      TraceBuilder.failure(kind, reason, stacktrace, "phoenix.error_rendered", Config.get())

    case EventCollector.record(
           "phoenix.error_rendered",
           "exception",
           %{status: status, kind: failure.kind, exception: failure.exception},
           outcome: "error",
           lifecycle: true
         ) do
      :no_context ->
        :ok

      _recorded ->
        EventCollector.put_failure(failure)
        EventCollector.finish(status)
    end
  end

  ## Ecto

  defp handle([_ | _] = event, measurements, %{type: :ecto_sql_query} = metadata) do
    # Check the buffer first so dropped queries cost no metadata building.
    if List.last(event) == :query and EventCollector.accepting?(),
      do: record_query(measurements, metadata, Config.get()),
      else: EventCollector.record_dropped()
  end

  defp handle(_event, _measurements, _metadata), do: :ok

  defp record_query(measurements, metadata, config) do
    {outcome, result_fields} =
      case metadata[:result] do
        {:ok, %{num_rows: rows}} -> {"ok", %{num_rows: rows}}
        {:ok, _} -> {"ok", %{}}
        {:error, %{__exception__: true} = e} -> {"error", %{error: inspect(e.__struct__)}}
        {:error, _} -> {"error", %{}}
        _ -> {nil, %{}}
      end

    fields =
      %{
        repo: module_name(metadata[:repo]),
        source: if(is_binary(metadata[:source]), do: metadata[:source]),
        query_time_us: us(measurements[:query_time]),
        queue_time_us: us(measurements[:queue_time]),
        decode_time_us: us(measurements[:decode_time]),
        origin: query_origin(metadata[:stacktrace], metadata[:repo])
      }
      |> Map.merge(result_fields)
      |> then(fn fields ->
        if config.capture_sql and is_binary(metadata[:query]),
          do: Map.put(fields, :sql, metadata.query),
          else: fields
      end)

    EventCollector.record("ecto.query", "db", fields,
      duration: measurements[:total_time],
      outcome: outcome
    )
  end

  # The first stack frame outside Ecto/DBConnection, available when the repo
  # is configured with `stacktrace: true`. Arguments are never included.
  defp query_origin(stacktrace, repo) when is_list(stacktrace) do
    stacktrace
    |> Enum.find(fn
      {mod, _fun, _arity, _loc} when is_atom(mod) ->
        mod != repo and not internal_query_module?(mod)

      _ ->
        false
    end)
    |> case do
      {mod, fun, arity, loc} ->
        arity = if is_list(arity), do: length(arity), else: arity
        location = if loc[:file], do: " (#{loc[:file]}:#{loc[:line]})", else: ""
        "#{inspect(mod)}.#{fun}/#{arity}#{location}"

      nil ->
        nil
    end
  end

  defp query_origin(_stacktrace, _repo), do: nil

  defp internal_query_module?(mod) do
    case Atom.to_string(mod) do
      "Elixir.Ecto." <> _ -> true
      "Elixir.DBConnection" <> _ -> true
      _ -> false
    end
  end

  # Plug wraps only :error exceptions in Plug.Conn.WrapperError, so for a
  # throw or an exit Phoenix renders the 500 with the conn that entered the
  # endpoint and TraceGuard.Plug's before_send never runs. The only later
  # signal, [:phoenix, :error_rendered], fires *after* the response is sent,
  # and Cowboy terminates the request process once its response is complete
  # (`exit(Pid, shutdown)`), so work done then can be cut short and the
  # report lost. Phoenix always renders throws and exits as 500
  # (Phoenix.Endpoint.RenderErrors), so the trace is completed here, before
  # anything is sent.
  defp complete_unwrapped(kind) when kind in [:throw, :exit] do
    EventCollector.record("request.stop", "request", %{status: 500},
      lifecycle: true,
      outcome: "error"
    )

    EventCollector.finish(500)
  end

  defp complete_unwrapped(_kind), do: :ok

  ## Helpers

  defp route_metadata(metadata) do
    %{
      route: metadata[:route],
      plug: module_name(metadata[:plug]),
      action: if(is_atom(metadata[:plug_opts]), do: metadata[:plug_opts]),
      pipe_through: Enum.filter(List.wrap(metadata[:pipe_through]), &is_atom/1)
    }
  end

  # inspect/1 on a module validates the alias segment by segment, which was
  # the largest TraceGuard cost on simple requests when profiled.
  defp module_name(nil), do: nil

  defp module_name(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      _ -> inspect(module)
    end
  end

  defp module_name(_), do: nil

  defp us(nil), do: nil
  defp us(native), do: System.convert_time_unit(native, :native, :microsecond)
end
