defmodule TraceGuard.Config do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Validated TraceGuard configuration.

  Configuration is read from the `:trace_guard` application environment when
  the application starts, validated, and cached in `:persistent_term` so the
  request hot path never re-validates it.

      config :trace_guard,
        failure_status: 500,
        max_events: 100,
        max_reports: 50,
        redact_keys: ["card_number"],
        capture_request_headers: ["accept", "content-type"],
        ecto_telemetry_prefixes: [[:my_app, :repo]]

  See `docs/configuration.md` for the full reference.
  """

  @default_redact_keys ~w(password authorization token access_token refresh_token secret api_key cookie private_key)

  @defaults [
    enabled: true,
    failure_status: 500,
    max_events: 100,
    max_reports: 50,
    redact_keys: [],
    capture_request_headers: ["accept", "content-type"],
    capture_path: false,
    capture_path_params: false,
    capture_sql: false,
    capture_exception_message: true,
    max_string_length: 500,
    max_stacktrace_frames: 20,
    response_header: "x-traceguard-id",
    incoming_header: nil,
    ecto_telemetry_prefixes: [],
    max_task_collectors: 1_000,
    task_drain_timeout: 100,
    task_collector_lifetime: 300_000,
    storage: TraceGuard.ReportStore,
    max_pending_reports: 50,
    max_drop_records: 1_000,
    drop_record_ttl: 600_000
  ]

  @key :"$trace_guard_config"

  @type t :: %__MODULE__{
          enabled: boolean(),
          failure_status: 100..599,
          max_events: pos_integer(),
          max_reports: pos_integer(),
          redact_keys: [String.t()],
          capture_request_headers: [String.t()],
          capture_path: boolean(),
          capture_path_params: boolean(),
          capture_sql: boolean(),
          capture_exception_message: boolean(),
          max_string_length: pos_integer(),
          max_stacktrace_frames: non_neg_integer(),
          response_header: String.t() | nil,
          incoming_header: String.t() | nil,
          ecto_telemetry_prefixes: [[atom()]],
          max_task_collectors: pos_integer(),
          task_drain_timeout: non_neg_integer(),
          task_collector_lifetime: pos_integer(),
          storage: module() | {module(), keyword()},
          max_pending_reports: pos_integer(),
          max_drop_records: pos_integer(),
          drop_record_ttl: pos_integer()
        }

  defstruct Keyword.keys(@defaults)

  @doc "Sensitive keys that are always redacted, in normalized form."
  @spec default_redact_keys() :: [String.t()]
  def default_redact_keys, do: @default_redact_keys

  @doc "Default option values."
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc """
  Returns the active configuration.

  Falls back to loading from the application environment if nothing has been
  cached yet (for example when TraceGuard functions are called before the
  application has started).
  """
  @spec get() :: t()
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> load!()
      config -> config
    end
  end

  @doc "Loads, validates and caches configuration from the application environment."
  @spec load!() :: t()
  def load! do
    :trace_guard
    |> Application.get_all_env()
    # `config :trace_guard, SomeModule, ...` entries belong to that module.
    |> Enum.reject(fn {key, _} -> module_key?(key) end)
    |> put!()
  end

  defp module_key?(key), do: match?("Elixir." <> _, Atom.to_string(key))

  @doc """
  Validates `opts`, merges them over the defaults and caches the result.

  Raises `ArgumentError` on invalid configuration. Intended for application
  start-up and tests; changing configuration at runtime rewrites a
  `:persistent_term`, which triggers a global GC and should be rare.
  """
  @spec put!(keyword()) :: t()
  def put!(opts) when is_list(opts) do
    config = validate!(opts)
    :persistent_term.put(@key, config)
    config
  end

  @doc "Validates `opts` without caching them."
  @spec validate!(keyword()) :: t()
  def validate!(opts) when is_list(opts) do
    known = Keyword.keys(@defaults)

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown :trace_guard options: #{inspect(unknown)}"
    end

    merged = Keyword.merge(@defaults, opts)

    %__MODULE__{
      enabled: boolean!(merged, :enabled),
      failure_status: status!(merged),
      max_events: pos_integer!(merged, :max_events),
      max_reports: pos_integer!(merged, :max_reports),
      redact_keys: redact_keys!(merged),
      capture_request_headers: headers!(merged),
      capture_path: boolean!(merged, :capture_path),
      capture_path_params: boolean!(merged, :capture_path_params),
      capture_sql: boolean!(merged, :capture_sql),
      capture_exception_message: boolean!(merged, :capture_exception_message),
      max_string_length: pos_integer!(merged, :max_string_length),
      max_stacktrace_frames: non_neg_integer!(merged, :max_stacktrace_frames),
      response_header: header_name!(merged, :response_header),
      incoming_header: header_name!(merged, :incoming_header),
      ecto_telemetry_prefixes: prefixes!(merged),
      max_task_collectors: pos_integer!(merged, :max_task_collectors),
      task_drain_timeout: non_neg_integer!(merged, :task_drain_timeout),
      task_collector_lifetime: pos_integer!(merged, :task_collector_lifetime),
      storage: storage!(merged),
      max_pending_reports: pos_integer!(merged, :max_pending_reports),
      max_drop_records: pos_integer!(merged, :max_drop_records),
      drop_record_ttl: pos_integer!(merged, :drop_record_ttl)
    }
  end

  defp boolean!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_boolean(value) -> value
      other -> invalid!(key, "a boolean", other)
    end
  end

  defp pos_integer!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 -> value
      other -> invalid!(key, "a positive integer", other)
    end
  end

  defp non_neg_integer!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value >= 0 -> value
      other -> invalid!(key, "a non-negative integer", other)
    end
  end

  defp status!(opts) do
    case Keyword.fetch!(opts, :failure_status) do
      value when is_integer(value) and value in 100..599 -> value
      other -> invalid!(:failure_status, "an HTTP status between 100 and 599", other)
    end
  end

  defp redact_keys!(opts) do
    extra =
      case Keyword.fetch!(opts, :redact_keys) do
        keys when is_list(keys) ->
          Enum.map(keys, fn
            key when is_binary(key) or is_atom(key) -> TraceGuard.Redactor.normalize_key(key)
            other -> invalid!(:redact_keys, "a list of strings or atoms", other)
          end)

        other ->
          invalid!(:redact_keys, "a list of strings or atoms", other)
      end

    Enum.uniq(@default_redact_keys ++ Enum.reject(extra, &(&1 == "")))
  end

  defp headers!(opts) do
    case Keyword.fetch!(opts, :capture_request_headers) do
      headers when is_list(headers) ->
        Enum.map(headers, fn
          header when is_binary(header) -> String.downcase(header)
          other -> invalid!(:capture_request_headers, "a list of header names", other)
        end)

      other ->
        invalid!(:capture_request_headers, "a list of header names", other)
    end
  end

  defp header_name!(opts, key) do
    case Keyword.fetch!(opts, key) do
      nil ->
        nil

      value when is_binary(value) ->
        if value =~ ~r/\A[a-zA-Z0-9-]+\z/,
          do: String.downcase(value),
          else: invalid!(key, "a header name or nil", value)

      other ->
        invalid!(key, "a header name or nil", other)
    end
  end

  defp prefixes!(opts) do
    case Keyword.fetch!(opts, :ecto_telemetry_prefixes) do
      prefixes when is_list(prefixes) ->
        Enum.map(prefixes, fn prefix ->
          if is_list(prefix) and prefix != [] and Enum.all?(prefix, &is_atom/1),
            do: prefix,
            else: invalid!(:ecto_telemetry_prefixes, "a list of atom lists", prefix)
        end)

      other ->
        invalid!(:ecto_telemetry_prefixes, "a list of atom lists", other)
    end
  end

  defp storage!(opts) do
    case Keyword.fetch!(opts, :storage) do
      module when is_atom(module) and not is_nil(module) ->
        module

      {module, adapter_opts} = storage when is_atom(module) and is_list(adapter_opts) ->
        storage

      other ->
        invalid!(:storage, "a module or {module, keyword}", other)
    end
  end

  defp invalid!(key, expected, value) do
    raise ArgumentError,
          "invalid :trace_guard option #{inspect(key)}: expected #{expected}, got: #{inspect(value)}"
  end
end
