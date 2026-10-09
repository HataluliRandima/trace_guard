defmodule TraceGuardDemoWeb.ProductController do
  use TraceGuardDemoWeb, :controller

  def index(conn, _params), do: json(conn, %{data: TraceGuardDemo.Shop.list_products()})

  def catalog(conn, _params), do: json(conn, %{data: TraceGuardDemo.Shop.catalog_summary()})

  def catalog_parallel(conn, _params),
    do: json(conn, %{data: TraceGuardDemo.Shop.catalog_summary_parallel()})
end
