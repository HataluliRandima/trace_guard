defmodule TraceGuard.Server do
  @moduledoc """
  Explicit trace propagation into selected `GenServer.call/3` operations.

  A GenServer is a long-lived process that serves many callers, so its work
  cannot be attributed to a request by "which process emitted the event"
  (Phase 1) or by wrapping a function (`TraceGuard.wrap/1`). Correlation
  therefore needs both sides to opt in:

      # The server: opt in once.
      defmodule MyApp.Pricing do
        use GenServer
        use TraceGuard.Server

        @impl true
        def handle_call({:quote, sku, qty}, _from, state) do
          price = MyApp.Repo.get_by!(Product, sku: sku).price_cents * qty   # traced
          {:reply, price, state}
        end
      end

      # The caller (e.g. a controller): opt in per call.
      TraceGuard.call(MyApp.Pricing, {:quote, "TG-001", 2})

  ## How it works

  `TraceGuard.call/3` is `GenServer.call(server, {TraceGuard.Server, token,
  request}, timeout)`. The token is the same one `TraceGuard.wrap/1` uses
  (trace ID, collector pid, atomics budget), or `nil` when the caller has no
  trace. `use TraceGuard.Server` overrides `handle_call/3`: messages of that
  shape are unwrapped, and *your* `handle_call(request, from, state)` runs
  with the caller's trace active **only for the duration of that callback**.
  Every other message (ordinary calls, casts, infos) goes to your callbacks
  unchanged and is never traced.

  ## What is traced, and what is not

  * Traced: telemetry events (Ecto queries, etc.) emitted by the server
    process **while it runs `handle_call/3` for a `TraceGuard.call/3`
    message**, plus `genserver.call.start`, `genserver.call.stop` and
    `genserver.call.exception` events. Each event carries `server` (module
    name) and `operation` (the request's leading atom, e.g. `:quote`); the
    request's data is never recorded.
  * Not traced: anything else the server does. That includes other callers'
    calls, `handle_cast`/`handle_info`/timeouts, work done after returning
    `{:noreply, state}` and replying later with `GenServer.reply/2`, and
    processes the server talks to (unless you propagate further with
    `TraceGuard.call/3` or `TraceGuard.wrap/1`, which works inside the
    callback).

  This is instrumentation of **selected calls**, not tracing of a server: a
  long-lived server's background activity never joins a request's trace.

  ## Semantics

  * **Isolation.** A GenServer handles one message at a time, and the trace
    context is set from the message's own token and removed (or restored) in
    an `after` block. Concurrent callers are serialized by the server, each
    with its own token, so their events cannot mix.
  * **Return values** are unchanged: `{:reply, ...}`, `{:noreply, ...}`,
    `{:stop, ...}` and `throw`-returns pass through.
  * **Exceptions and exits** in the callback are recorded as
    `genserver.call.exception` (kind and exception module only), then
    re-raised with the original stacktrace. The server crashes and the
    caller exits exactly as with `GenServer.call/3`.
  * **Timeouts** behave as with `GenServer.call/3`: the caller exits after
    `timeout`. If the server still processes the message, its events reach
    the trace only if it is still live (otherwise they are dropped, as for
    late tasks).
  * **Restarts.** The token does not reference the server, so a restarted
    server serves traced calls normally. A call to a server that is down
    exits the caller with the usual `:noproc` reason.
  * **Nesting.** Inside a traced callback, `TraceGuard.call/3` and
    `TraceGuard.wrap/1` propagate the same token further.
  * **Untraced callers.** With no active trace (or TraceGuard disabled) the
    message still has the wrapped shape and the token is `nil`; the server
    just runs the callback. The shape never depends on tracing, so a server
    that forgot `use TraceGuard.Server` fails the same way in every
    environment (a `FunctionClauseError` in its `handle_call/3`).
  * **Waiting.** TraceGuard adds no waiting and no queue. Budgets and
    collector limits are those of `TraceGuard.wrap/1`.
  """

  alias TraceGuard.Propagation

  @doc """
  Like `GenServer.call/3`, carrying the caller's trace to a server that
  uses `TraceGuard.Server`.
  """
  @spec call(GenServer.server(), term(), timeout()) :: term()
  def call(server, request, timeout \\ 5000) do
    GenServer.call(server, {__MODULE__, Propagation.capture(), request}, timeout)
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @before_compile TraceGuard.Server
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # If every handle_call/3 clause comes from `use GenServer`'s default
    # (its clauses carry `context: GenServer`), the module defines no calls
    # of its own: there is nothing to trace.
    if only_default_handle_call?(env.module) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "use TraceGuard.Server in #{inspect(env.module)} requires a handle_call/3 " <>
            "definition (TraceGuard.Server only traces calls)"
    end

    quote do
      defoverridable handle_call: 3

      def handle_call({TraceGuard.Server, token, request}, from, state) do
        TraceGuard.Propagation.run_server_call(token, __MODULE__, request, fn ->
          super(request, from, state)
        end)
      end

      def handle_call(request, from, state), do: super(request, from, state)
    end
  end

  defp only_default_handle_call?(module) do
    case Module.get_definition(module, {:handle_call, 3}) do
      {:v1, _kind, _meta, clauses} ->
        Enum.all?(clauses, fn {meta, _args, _guards, _body} -> meta[:context] == GenServer end)

      nil ->
        true
    end
  end
end
