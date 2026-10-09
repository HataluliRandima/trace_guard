defmodule TraceGuardDemo.Shop do
  @moduledoc """
  The demo's business logic. Note that it contains no TraceGuard code at all:
  everything in a diagnostic report comes from Phoenix and Ecto telemetry.
  """

  import Ecto.Query

  alias TraceGuardDemo.{Payments, Repo}
  alias TraceGuardDemo.Shop.{Order, Product}

  def list_products do
    Repo.all(from p in Product, order_by: p.id)
  end

  @doc """
  Reserves stock, records a pending order and charges the card, all inside a
  transaction. The payment step always fails in the demo, so the transaction
  rolls back and the exception propagates to Phoenix.
  """
  def checkout(%{"sku" => sku, "quantity" => quantity} = params) when is_integer(quantity) do
    Repo.transaction(fn ->
      product = Repo.one!(from p in Product, where: p.sku == ^sku)

      {1, _} =
        Repo.update_all(
          from(p in Product, where: p.id == ^product.id and p.stock >= ^quantity),
          inc: [stock: -quantity]
        )

      order =
        Repo.insert!(%Order{
          product_id: product.id,
          quantity: quantity,
          total_cents: product.price_cents * quantity,
          status: "pending"
        })

      Payments.charge(order.total_cents, Map.get(params, "card", %{}))
    end)
  end
end
