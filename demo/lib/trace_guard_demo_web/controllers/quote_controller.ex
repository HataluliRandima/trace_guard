defmodule TraceGuardDemoWeb.QuoteController do
  use TraceGuardDemoWeb, :controller

  # GenServer propagation example. "TG-002" crashes the pricing server: the
  # caller exits (as with any GenServer.call/3), and Phoenix returns a 500.
  def create(conn, %{"sku" => sku, "qty" => qty}) when is_integer(qty) do
    case TraceGuardDemo.Pricing.quote(sku, qty) do
      {:ok, quote} ->
        json(conn, %{data: quote})

      {:error, :unknown_sku} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "unknown sku"}})
    end
  end
end
