defmodule TraceGuardDemoWeb.CheckoutController do
  use TraceGuardDemoWeb, :controller

  # Deliberately failing endpoint: TraceGuardDemo.Payments always raises.
  # No rescue here; Phoenix's normal error handling produces the 500.
  def create(conn, params) do
    {:ok, order} = TraceGuardDemo.Shop.checkout(params)
    json(conn, %{data: order})
  end
end
