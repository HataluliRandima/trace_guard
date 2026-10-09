defmodule TraceGuard.ReportStore do
  @moduledoc """
  The default `TraceGuard.Storage` adapter: a bounded, in-memory store of
  finished (already redacted) reports in one GenServer.

  ## Bounds

  * **Retained reports:** at most `:max_reports`; the oldest is evicted first.
  * **Queued submissions:** at most `:max_pending_reports`. Admission happens
    in the *submitting* process, before anything is sent: each store
    incarnation publishes its pid and an `:atomics` counter once (in
    `:persistent_term`). A submitter increments the counter and only sends
    if the result is within the limit; the store decrements it as it takes
    each submission. When the limit is reached, `put/2` returns
    `{:error, :overloaded}` immediately and nothing is sent. The store's
    mailbox therefore never holds more than `:max_pending_reports`
    submissions, however many requests fail at once. (Reads are synchronous
    calls and add at most one message per waiting caller.)
  * **Waiting:** `put/2` never waits. Reads wait at most the facade's
    `:timeout`, else `:call_timeout` (adapter option, default 5000 ms), and
    return `{:error, :unavailable}` instead of exiting.

  ## Outcomes

  * `{:ok, :queued}` means admitted; `[:trace_guard, :report, :stored]` is
    emitted once it is retained.
  * `{:error, :overloaded}`: the queue is full; the report is not kept.
  * `{:error, :unavailable}`: no live store (for example while it restarts).

  ## Restarts

  The store is supervised. A restart loses the retained reports and any
  admitted submissions still queued; the number of those lost submissions is
  added to the `:lost` statistic (their trace IDs are unknown). The new
  incarnation starts with an empty queue and a fresh admission counter.
  Nothing is written to disk or sent over the network.
  """

  @behaviour TraceGuard.Storage

  use GenServer

  alias TraceGuard.{Config, Storage}

  @admission {__MODULE__, :admission}
  @default_call_timeout 5_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## TraceGuard.Storage callbacks (run in the calling process)

  @impl Storage
  def put(%{"trace_id" => _} = report, _opts) do
    case :persistent_term.get(@admission, nil) do
      {pid, pending} ->
        if Process.alive?(pid), do: admit(pid, pending, report), else: {:error, :unavailable}

      nil ->
        {:error, :unavailable}
    end
  end

  defp admit(pid, pending, report) do
    if :atomics.add_get(pending, 1, 1) <= Config.get().max_pending_reports do
      send(pid, {:put, report})
      {:ok, :queued}
    else
      :atomics.sub(pending, 1, 1)
      {:error, :overloaded}
    end
  end

  @impl Storage
  def get(trace_id, opts), do: call({:get, trace_id}, opts)

  @impl Storage
  def list(opts), do: call(:list, opts)

  @impl Storage
  def delete(trace_id, opts), do: call({:delete, trace_id}, opts)

  @impl Storage
  def clear(opts), do: call(:clear, opts)

  @impl Storage
  def stats(opts) do
    case call(:stats, opts) do
      {:error, :unavailable} -> %{adapter: __MODULE__, available: false}
      stats -> stats
    end
  end

  defp call(message, opts) do
    timeout = Keyword.get(opts, :timeout, Keyword.get(opts, :call_timeout, @default_call_timeout))
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  ## GenServer

  @impl GenServer
  def init(_opts) do
    # Submissions admitted by a previous incarnation died with its mailbox.
    lost =
      case :persistent_term.get(@admission, nil) do
        {_old_pid, old_pending} -> :atomics.get(old_pending, 1)
        nil -> 0
      end

    if lost > 0, do: Storage.lost(lost)

    pending = :atomics.new(1, [])
    :persistent_term.put(@admission, {self(), pending})

    {:ok, %{pending: pending, order: :queue.new(), reports: %{}, evicted: 0}}
  end

  @impl GenServer
  def handle_info({:put, %{"trace_id" => id} = report}, state) do
    :atomics.sub(state.pending, 1, 1)

    state =
      if Map.has_key?(state.reports, id) do
        %{state | reports: Map.put(state.reports, id, report)}
      else
        %{state | order: :queue.in(id, state.order), reports: Map.put(state.reports, id, report)}
      end

    state = evict(state, Config.get().max_reports)
    Storage.stored(report)
    {:noreply, state}
  end

  def handle_info(_unexpected, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:get, id}, _from, state) do
    reply = with :error <- Map.fetch(state.reports, id), do: :error
    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    summaries =
      state.order
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.map(&Storage.summary(state.reports[&1]))

    {:reply, summaries, state}
  end

  def handle_call({:delete, id}, _from, state) do
    state = %{
      state
      | reports: Map.delete(state.reports, id),
        order: :queue.delete(id, state.order)
    }

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state),
    do: {:reply, :ok, %{state | order: :queue.new(), reports: %{}}}

  def handle_call(:stats, _from, state) do
    config = Config.get()

    stats = %{
      adapter: __MODULE__,
      available: true,
      retained: map_size(state.reports),
      max_reports: config.max_reports,
      pending: :atomics.get(state.pending, 1),
      max_pending_reports: config.max_pending_reports,
      evicted: state.evicted
    }

    {:reply, stats, state}
  end

  defp evict(state, max) do
    if map_size(state.reports) > max do
      {{:value, oldest}, order} = :queue.out(state.order)

      evict(
        %{
          state
          | order: order,
            reports: Map.delete(state.reports, oldest),
            evicted: state.evicted + 1
        },
        max
      )
    else
      state
    end
  end
end
