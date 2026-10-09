defmodule TraceGuard.TestStorage do
  @moduledoc false
  # A minimal synchronous TraceGuard.Storage adapter backed by an Agent. It
  # shows the tracing engine does not depend on TraceGuard.ReportStore, and
  # can simulate adapter failures.
  #
  # Options (from `config :trace_guard, storage: {TraceGuard.TestStorage, opts}`):
  #   * :mode - :store (default), :overloaded, :raise, :exit, :bad_result,
  #             :emit_event (stores, but emits an Ecto-shaped event first)
  #   * :max  - retained reports (default 3)

  @behaviour TraceGuard.Storage

  @impl true
  def child_spec(_opts) do
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__]]}}
  end

  @impl true
  def put(%{"trace_id" => id} = report, opts) do
    case Keyword.get(opts, :mode, :store) do
      :store ->
        store(id, report, opts)

      :emit_event ->
        TraceGuard.TestApp.emit_query("emitted_by_storage")
        store(id, report, opts)

      :overloaded ->
        {:error, :overloaded}

      :raise ->
        raise "storage adapter bug"

      :exit ->
        exit(:storage_down)

      :bad_result ->
        :ok
    end
  end

  defp store(id, report, opts) do
    max = Keyword.get(opts, :max, 3)

    Agent.update(__MODULE__, fn entries ->
      [{id, report} | List.keydelete(entries, id, 0)] |> Enum.take(max)
    end)

    {:ok, :stored}
  end

  @impl true
  def get(id, _opts) do
    case Agent.get(__MODULE__, &List.keyfind(&1, id, 0)) do
      {^id, report} -> {:ok, report}
      nil -> :error
    end
  end

  @impl true
  def list(_opts),
    do:
      Agent.get(__MODULE__, fn entries ->
        Enum.map(entries, &TraceGuard.Storage.summary(elem(&1, 1)))
      end)

  @impl true
  def delete(id, _opts), do: Agent.update(__MODULE__, &List.keydelete(&1, id, 0))

  @impl true
  def clear(_opts), do: Agent.update(__MODULE__, fn _ -> [] end)

  @impl true
  def stats(_opts), do: %{adapter: __MODULE__, retained: Agent.get(__MODULE__, &length/1)}
end
