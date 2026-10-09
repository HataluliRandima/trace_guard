defmodule TraceGuardDemoWeb.ProductController do
  use TraceGuardDemoWeb, :controller

  def index(conn, _params), do: json(conn, %{data: TraceGuardDemo.Shop.list_products()})
end
