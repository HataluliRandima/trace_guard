defmodule TraceGuardDemo.Fixtures do
  @moduledoc false

  alias TraceGuardDemo.Repo
  alias TraceGuardDemo.Shop.Product

  def product!(attrs \\ %{}) do
    Repo.insert!(
      struct!(%Product{sku: "TG-001", name: "Trace Lens", price_cents: 4_900, stock: 25}, attrs)
    )
  end

  # Sensitive values sent with every failing request. None may appear in a
  # TraceGuard report.
  def secrets do
    [
      "hunter2",
      "4242424242424242",
      "demo_merchant_key_123",
      "demo-user-session-token",
      "demo-client-key-123"
    ]
  end

  def checkout_body do
    Jason.encode!(%{
      sku: "TG-001",
      quantity: 2,
      password: "hunter2",
      card: %{card_number: "4242424242424242", cvc: "123"}
    })
  end

  def checkout_headers do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer demo-user-session-token"},
      {"x-api-key", "demo-client-key-123"}
    ]
  end

  def trace_id(headers) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if to_string(k) == "x-traceguard-id", do: to_string(v)
    end)
  end

  # Event-driven (TraceGuard.await_report/2), no polling.
  def fetch_report!(trace_id, timeout \\ 1_000) do
    case TraceGuard.await_report(trace_id, timeout) do
      {:ok, report} -> report
      other -> raise "no report for #{inspect(trace_id)}: #{inspect(other)}"
    end
  end

  @doc """
  For responses without an x-traceguard-id header (exits, throws): waits for
  the stored report of `route`. Subscribes to TraceGuard's report events
  before checking, so a report stored in between is not missed.
  """
  def fetch_report_for_route!(route, timeout \\ 1_000) do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:trace_guard, :report, :stored],
      &__MODULE__.forward_stored/4,
      parent
    )

    try do
      case TraceGuard.list_reports(route: route) do
        [%{"trace_id" => id} | _] ->
          fetch_report!(id)

        [] ->
          receive do
            {:trace_guard_stored, id, %{"route" => ^route}} -> fetch_report!(id)
          after
            timeout -> raise "no report for route #{route}"
          end
      end
    after
      :telemetry.detach(handler)
    end
  end

  def forward_stored(_event, _measurements, meta, pid),
    do: send(pid, {:trace_guard_stored, meta.trace_id, meta.summary})

  def ecto_sql(report) do
    for %{"name" => "ecto.query", "metadata" => meta} <- report["events"], do: meta["sql"]
  end
end
