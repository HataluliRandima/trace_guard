defmodule TraceGuard.Context do
  @moduledoc """
  Request-local trace context.

  ## Correlation strategy

  A Phoenix request is handled from start to finish by a single process (one
  Cowboy stream process, or one Bandit connection/stream process), and
  `:telemetry` handlers run synchronously *in the process that emits the
  event*. TraceGuard relies on exactly these two facts:

    1. `TraceGuard.Plug` stores a fresh context in the **request process's**
       process dictionary under a private key.
    2. A telemetry handler appends an event only if the emitting process has
       an active context. The event therefore belongs to that request by
       construction, not by timing heuristics.

  Consequences, which are deliberate and documented:

    * Events emitted by *other* processes (for example a `Task` started by a
      controller, or a query run inside a `GenServer`) find no context and are
      ignored. The process dictionary does not propagate across processes and
      TraceGuard does not pretend otherwise.
    * In-flight state is only reachable from its own process, so one request
      can never read or append to another request's trace.
    * Bandit reuses a process for keep-alive requests on the same
      connection. Each new request replaces any stale context, and contexts
      are removed when the request completes.
  """

  @key {__MODULE__, :ctx}

  @enforce_keys [:trace_id, :started_mono, :started_at, :request]
  defstruct [
    :trace_id,
    :started_mono,
    :started_at,
    :request,
    :failure,
    events: [],
    seq: 0,
    retained: 0,
    dropped: 0
  ]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          started_mono: integer(),
          started_at: DateTime.t(),
          request: map(),
          failure: map() | nil,
          events: [map()],
          seq: non_neg_integer(),
          retained: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @doc """
  Generates a new trace ID: 128 random bits as 32 lowercase hex characters
  (the same shape as a W3C Trace Context trace-id).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  @doc "Returns true if `value` has the shape of a TraceGuard trace ID."
  @spec valid_trace_id?(term()) :: boolean()
  def valid_trace_id?(value) when is_binary(value) and byte_size(value) == 32,
    do: value =~ ~r/\A[0-9a-f]{32}\z/

  def valid_trace_id?(_), do: false

  @doc "Starts a new context in the calling process, replacing any stale one."
  @spec start(String.t(), map()) :: t()
  def start(trace_id, request) when is_binary(trace_id) and is_map(request) do
    ctx = %__MODULE__{
      trace_id: trace_id,
      started_mono: System.monotonic_time(),
      started_at: DateTime.utc_now(),
      request: request
    }

    Process.put(@key, ctx)
    ctx
  end

  @doc "Returns the calling process's active context, or nil."
  @spec current() :: t() | nil
  def current, do: Process.get(@key)

  @doc "Stores an updated context for the calling process."
  @spec put(t()) :: :ok
  def put(%__MODULE__{} = ctx) do
    Process.put(@key, ctx)
    :ok
  end

  @doc "Removes and returns the calling process's context."
  @spec take() :: t() | nil
  def take, do: Process.delete(@key)
end
