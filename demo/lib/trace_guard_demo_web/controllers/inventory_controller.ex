defmodule TraceGuardDemoWeb.InventoryController do
  use TraceGuardDemoWeb, :controller

  # A failure without an exception: the upstream warehouse is "unavailable",
  # so the controller answers 503 after reading the catalogue.
  def sync(conn, _params) do
    _products = TraceGuardDemo.Shop.list_products()

    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "warehouse unavailable"}})
  end
end
