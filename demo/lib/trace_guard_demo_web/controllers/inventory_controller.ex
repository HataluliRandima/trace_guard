defmodule TraceGuardDemoWeb.InventoryController do
  use TraceGuardDemoWeb, :controller

  # A failure without an exception: the upstream warehouse is "unavailable",
  # so the controller answers 503 after reading the catalogue.
  def audit(conn, _params), do: json(conn, %{data: TraceGuardDemo.Shop.audit_inventory()})

  # Deliberate failure in a child task (see Shop.reconcile_inventory/0).
  def reconcile(conn, _params) do
    {_local, _feed} = TraceGuardDemo.Shop.reconcile_inventory()
    json(conn, %{data: "reconciled"})
  end

  def sync(conn, _params) do
    _products = TraceGuardDemo.Shop.list_products()

    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "warehouse unavailable"}})
  end
end
