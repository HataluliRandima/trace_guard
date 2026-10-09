defmodule TraceGuard.ReportStore do
  @moduledoc """
  Bounded, in-memory store of finished (already redacted) failure reports.

  * Holds at most `:max_reports` reports; the oldest is evicted first.
  * Writes are asynchronous casts so a failing request never blocks on the
    store. A report becomes readable shortly after its response is sent.
  * Nothing is written to disk or sent over the network.
  * Reports are keyed by their unguessable 128-bit trace ID.
  """

  use GenServer

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stores a report asynchronously. Returns `:ok` even if the store is down."
  @spec put(map()) :: :ok
  def put(%{"trace_id" => _} = report), do: GenServer.cast(__MODULE__, {:put, report})

  @doc "Fetches a report by trace ID."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(trace_id), do: GenServer.call(__MODULE__, {:get, trace_id})

  @doc "Returns all stored reports, newest first."
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Removes all stored reports."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_opts), do: {:ok, %{order: :queue.new(), reports: %{}}}

  @impl true
  def handle_cast({:put, %{"trace_id" => id} = report}, state) do
    max = TraceGuard.Config.get().max_reports

    state =
      if Map.has_key?(state.reports, id) do
        %{state | reports: Map.put(state.reports, id, report)}
      else
        %{order: :queue.in(id, state.order), reports: Map.put(state.reports, id, report)}
      end

    {:noreply, evict(state, max)}
  end

  @impl true
  def handle_call({:get, id}, _from, state), do: {:reply, Map.fetch(state.reports, id), state}

  def handle_call(:list, _from, state) do
    reports = state.order |> :queue.to_list() |> Enum.reverse() |> Enum.map(&state.reports[&1])
    {:reply, reports, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{order: :queue.new(), reports: %{}}}

  defp evict(state, max) do
    if map_size(state.reports) > max do
      {{:value, oldest}, order} = :queue.out(state.order)
      evict(%{order: order, reports: Map.delete(state.reports, oldest)}, max)
    else
      state
    end
  end
end
