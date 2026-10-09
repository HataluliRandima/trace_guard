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

  def fetch_report!(trace_id, attempts \\ 50) do
    case TraceGuard.get_report(trace_id) do
      {:ok, report} ->
        report

      {:error, :not_found} when attempts > 0 ->
        Process.sleep(2)
        fetch_report!(trace_id, attempts - 1)

      other ->
        raise "no report for #{inspect(trace_id)}: #{inspect(other)}"
    end
  end

  @doc """
  For responses without an x-traceguard-id header (exits, throws): waits
  for the asynchronously stored report of `route` and returns it.
  """
  def fetch_report_for_route!(route, attempts \\ 50) do
    case Enum.find(TraceGuard.list_reports(), &(&1["route"] == route)) do
      %{"trace_id" => id} ->
        fetch_report!(id)

      nil when attempts > 0 ->
        Process.sleep(2)
        fetch_report_for_route!(route, attempts - 1)

      nil ->
        raise "no report for route #{route}"
    end
  end

  def ecto_sql(report) do
    for %{"name" => "ecto.query", "metadata" => meta} <- report["events"], do: meta["sql"]
  end
end
