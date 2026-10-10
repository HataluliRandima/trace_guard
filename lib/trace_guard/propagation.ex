defmodule TraceGuard.Propagation do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Explicit, opt-in propagation of a request's trace into selected processes.

  Telemetry handlers run in the process that emits an event, and
  `TraceGuard.Context` lives in the request process's dictionary, so work done
  in a `Task` is invisible by default. `TraceGuard.wrap/1` (implemented here)
  binds a function to the *current* trace so that events emitted while it
  runs, in whichever process, are added to that trace:

      Task.async(TraceGuard.wrap(fn -> Repo.all(Product) end))

  ## What is propagated

  Only a `TraceGuard.Propagation.Token`: the trace ID, the pid of the trace's
  task collector and an `:atomics` counter. No request data, headers,
  credentials or other process-dictionary entries are copied.

  ## How events travel

  The first `wrap/1` call in a request starts a `TraceGuard.TaskCollector`
  (one per trace, under a bounded `DynamicSupervisor`). A process running
  wrapped work holds a task context for exactly the duration of the function;
  its events are sent to the collector as messages. All processes of one
  trace share the atomics counter, so at most `:max_events` task events are
  ever sent, regardless of the number of tasks. When the request completes,
  the collector is drained (failed request, bounded by `:task_drain_timeout`)
  or discarded (successful request).

  ## Semantics

    * **Opt-in.** Unwrapped tasks inherit nothing.
    * **Same trace ID.** Wrapped work never starts a new trace.
    * **Nesting.** Wrapping inside wrapped work reuses the same token, so
      grandchildren report into the same trace. Calling a wrapped function in
      the process that owns the trace just calls the function.
    * **Completion.** Events that reach the collector after the request
      completed are dropped. Await tasks before responding if their events
      matter.
    * **Errors.** The wrapper never rescues: results, raises, throws and exits
      pass through unchanged (re-raised with the original stacktrace). A
      failure is recorded as a `task.exception` event first.
    * **No blocking.** Children never wait for TraceGuard. The request process
      waits at most `:task_drain_timeout` ms, only for failed requests.
  """

  alias TraceGuard.{Config, Context, EventCollector, TaskCollector}

  defmodule Token do
    @moduledoc """
    **Internal.** The opaque value `TraceGuard.wrap/1` and `TraceGuard.call/3`
    carry into other processes: a trace ID, the trace's collector pid and an
    `:atomics` budget reference. Never construct or inspect it.
    """
    @enforce_keys [:trace_id, :collector, :counter]
    defstruct [:trace_id, :collector, :counter]

    @type t :: %__MODULE__{
            trace_id: String.t(),
            collector: pid(),
            counter: :atomics.atomics_ref()
          }
  end

  # Indexes in the shared :atomics counter.
  @sent 1
  @dropped 2

  @doc """
  Binds `fun` (arity 0 or 1) to the calling process's trace.

  Returns `fun` unchanged when there is no active trace, when TraceGuard is
  disabled, or when the collector limit is reached.
  """
  @spec wrap(fun) :: fun when fun: (-> any) | (any -> any)
  def wrap(fun) when is_function(fun, 0) or is_function(fun, 1) do
    case capture() do
      nil -> fun
      token -> bind(token, fun)
    end
  end

  # How work run under a token is labelled and which lifecycle events it
  # records. A `throw` from a GenServer callback is a valid way to return a
  # reply (gen_server catches it), so for servers it counts as a return.
  @task %{
    kind: "task",
    type: "task",
    start: "task.start",
    stop: "task.stop",
    exception: "task.exception",
    metadata: %{},
    throw_returns?: false
  }

  defp bind(token, fun) when is_function(fun, 0), do: fn -> run(token, fun, [], @task) end
  defp bind(token, fun) when is_function(fun, 1), do: fn arg -> run(token, fun, [arg], @task) end

  @doc false
  # The token for the calling process's trace, starting its collector if
  # needed; nil when there is no active trace (or the collector limit is
  # reached). Used by wrap/1 and TraceGuard.Server.call/3.
  @spec capture() :: Token.t() | nil
  def capture do
    case Context.current() do
      %Context{tasks: %Token{} = token} ->
        token

      %Context{role: :request, tasks: nil} = ctx ->
        start_collector(ctx)

      _no_trace_or_unavailable ->
        nil
    end
  end

  defp start_collector(ctx) do
    config = Config.get()

    case TaskCollector.start(ctx.trace_id, config) do
      {:ok, pid} ->
        token = %Token{trace_id: ctx.trace_id, collector: pid, counter: :atomics.new(2, [])}
        Context.put(%{ctx | tasks: token})
        token

      {:error, _reason} ->
        # Most likely :max_children (:max_task_collectors). Remember it so the
        # report can say task events are missing, and do not retry.
        Context.put(%{ctx | tasks: :unavailable})
        nil
    end
  end

  @doc false
  # Runs a GenServer callback (as a 0-arity fun) under `token`, if any.
  def run_server_call(nil, _server, _request, fun), do: fun.()

  # A token from another node (a call to a remote server) is unusable here:
  # its :atomics reference is node-local. Run the callback untraced rather
  # than risk an error inside the server's handle_call/3.
  def run_server_call(%Token{collector: collector}, _server, _request, fun)
      when node(collector) != node(),
      do: fun.()

  def run_server_call(%Token{} = token, server, request, fun) do
    spec = %{
      kind: "server",
      type: "genserver",
      start: "genserver.call.start",
      stop: "genserver.call.stop",
      exception: "genserver.call.exception",
      metadata: %{server: module_name(server), operation: operation(request)},
      throw_returns?: true
    }

    run(token, fun, [], spec)
  end

  # Only a code-defined atom naming the operation is recorded, never the
  # request's data: :refresh, or :quote for {:quote, sku, qty}.
  defp operation(request) when is_atom(request), do: request

  defp operation(request) when is_tuple(request) and is_atom(elem(request, 0)),
    do: elem(request, 0)

  defp operation(_request), do: nil

  defp module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      other -> other
    end
  end

  defp run(%Token{trace_id: trace_id} = token, fun, args, spec) do
    case Context.current() do
      # Already in the process that owns this trace: nothing to propagate.
      %Context{trace_id: ^trace_id, role: :request} ->
        apply(fun, args)

      previous ->
        run_in_context(token, previous, fun, args, spec)
    end
  end

  defp run_in_context(token, previous, fun, args, spec) do
    previous_logger_id = Logger.metadata()[:trace_guard_id]

    Context.put(%Context{
      trace_id: token.trace_id,
      started_mono: System.monotonic_time(),
      started_at: nil,
      role: :task,
      tasks: token,
      request: %{kind: spec.kind}
    })

    Logger.metadata(trace_guard_id: token.trace_id)
    started = System.monotonic_time()
    EventCollector.record(spec.start, spec.type, spec.metadata)

    try do
      result = apply(fun, args)

      EventCollector.record(spec.stop, spec.type, spec.metadata,
        duration: System.monotonic_time() - started,
        outcome: "ok"
      )

      result
    catch
      :throw, value when spec.throw_returns? ->
        EventCollector.record(spec.stop, spec.type, spec.metadata,
          duration: System.monotonic_time() - started,
          outcome: "ok"
        )

        throw(value)

      kind, reason ->
        EventCollector.record(
          spec.exception,
          spec.type,
          Map.merge(spec.metadata, %{
            kind: Atom.to_string(kind),
            exception: exception_name(kind, reason)
          }),
          duration: System.monotonic_time() - started,
          outcome: "error"
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      restore(previous)
      Logger.metadata(trace_guard_id: previous_logger_id)
    end
  end

  defp restore(nil), do: Context.take()
  defp restore(previous), do: Context.put(previous)

  defp exception_name(:error, reason) do
    %module{} = Exception.normalize(:error, reason)
    module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp exception_name(_kind, _reason), do: nil

  ## Used by EventCollector in task contexts

  @doc false
  # Sends an event to the trace's collector if the shared budget allows it.
  # Runs inside application code (task functions, server callbacks), so it
  # must never raise.
  def send_event(%Token{} = token, kind, event, max_events) do
    if :atomics.add_get(token.counter, @sent, 1) <= max_events do
      send(token.collector, {:trace_guard_event, token.trace_id, self(), kind, event})
      :ok
    else
      :atomics.add(token.counter, @dropped, 1)
      :dropped
    end
  rescue
    ArgumentError -> :dropped
  end

  @doc false
  def accepting?(%Token{} = token, max_events),
    do: :atomics.get(token.counter, @sent) < max_events

  @doc false
  def count_dropped(%Token{} = token), do: :atomics.add(token.counter, @dropped, 1)

  ## Used when the owning request completes

  @doc false
  # Collects the task events of a failed request. Never raises and never waits
  # longer than `timeout` ms.
  @spec drain(Token.t(), non_neg_integer()) ::
          {:ok, [map()], non_neg_integer()} | {:timeout | :unavailable, non_neg_integer()}
  def drain(%Token{} = token, timeout) do
    sender_dropped = :atomics.get(token.counter, @dropped)

    try do
      {events, collector_dropped} = GenServer.call(token.collector, :drain, timeout)
      {:ok, events, sender_dropped + collector_dropped}
    catch
      :exit, {:timeout, _} ->
        discard(token)
        {:timeout, sender_dropped}

      :exit, _reason ->
        {:unavailable, sender_dropped}
    end
  end

  @doc false
  # Stops the collector without waiting. Late events to a stopped collector
  # are silently dropped by the runtime.
  def discard(%Token{collector: pid}) do
    send(pid, :discard)
    :ok
  end
end
