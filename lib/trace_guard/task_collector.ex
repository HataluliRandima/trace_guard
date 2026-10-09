defmodule TraceGuard.TaskCollector do
  @moduledoc """
  Receives the events of propagated (wrapped) work for one trace.

  One collector exists per trace that called `TraceGuard.wrap/1`, started
  under the `TraceGuard.TaskCollectors` `DynamicSupervisor`, whose
  `max_children` is `:max_task_collectors`.

  A collector always terminates, whichever happens first:

    * the owning request process asks for its events (`:drain`) or discards
      it when the request completes;
    * the owning request process exits (it is monitored);
    * `:task_collector_lifetime` elapses.

  It stores at most `:max_events` events (senders are also budgeted through
  the shared `:atomics` counter) and labels them by sending process in
  order of first appearance, per kind: `"task-1"`, `"task-2"`,
  `"server-1"`, ...
  """

  use GenServer, restart: :temporary

  @supervisor TraceGuard.TaskCollectors

  @doc false
  # Returns {:error, reason} (never exits) when the limit is reached or the
  # supervisor is not running, so wrap/1 can fall back to the plain function.
  def start(trace_id, config) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__,
       owner: self(),
       trace_id: trace_id,
       max_events: config.max_events,
       lifetime: config.task_collector_lifetime}
    )
  catch
    :exit, reason -> {:error, {:supervisor_unavailable, reason}}
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))
    Process.send_after(self(), :expire, Keyword.fetch!(opts, :lifetime))

    {:ok,
     %{
       trace_id: Keyword.fetch!(opts, :trace_id),
       owner_ref: owner_ref,
       max_events: Keyword.fetch!(opts, :max_events),
       events: [],
       count: 0,
       dropped: 0,
       labels: %{}
     }}
  end

  @impl true
  def handle_info({:trace_guard_event, trace_id, pid, kind, event}, %{trace_id: trace_id} = state) do
    if state.count < state.max_events do
      {label, labels} = label(state.labels, pid, kind)
      event = Map.put(event, :process, label)

      {:noreply,
       %{state | events: [event | state.events], count: state.count + 1, labels: labels}}
    else
      {:noreply, %{state | dropped: state.dropped + 1}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info(:discard, state), do: {:stop, :normal, state}
  def handle_info(_unexpected, state), do: {:noreply, state}

  @impl true
  def handle_call(:drain, _from, state) do
    {:stop, :normal, {Enum.reverse(state.events), state.dropped}, state}
  end

  # One label per {process, kind}: "task-1", "task-2", "server-1", ...
  # numbered per kind in order of first appearance.
  defp label(labels, pid, kind) do
    case labels do
      %{{^pid, ^kind} => label} ->
        {label, labels}

      _ ->
        n = Enum.count(labels, fn {{_pid, k}, _label} -> k == kind end) + 1
        label = "#{kind}-#{n}"
        {label, Map.put(labels, {pid, kind}, label)}
    end
  end
end
