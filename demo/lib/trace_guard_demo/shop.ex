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

  @doc "A read-only summary built from several independent queries."
  def catalog_summary do
    %{
      products: list_products(),
      product_count: Repo.aggregate(Product, :count),
      units_in_stock: Repo.aggregate(Product, :sum, :stock) || 0,
      order_count: Repo.aggregate(Order, :count)
    }
  end

  @doc """
  The same summary as `catalog_summary/0`, with each query in its own Task.

  The tasks are wrapped with `TraceGuard.wrap/1` so that their queries join
  the request's trace; without it they would be invisible to TraceGuard.
  This is the only TraceGuard call in the demo's business logic, and it is
  opt-in.
  """
  def catalog_summary_parallel do
    [products, product_count, units, order_count] =
      [
        fn -> list_products() end,
        fn -> Repo.aggregate(Product, :count) end,
        fn -> Repo.aggregate(Product, :sum, :stock) || 0 end,
        fn -> Repo.aggregate(Order, :count) end
      ]
      |> Enum.map(&Task.async(TraceGuard.wrap(&1)))
      |> Task.await_many()

    %{
      products: products,
      product_count: product_count,
      units_in_stock: units,
      order_count: order_count
    }
  end

  defmodule WarehouseError do
    defexception [:message]
  end

  @doc """
  Compares local stock with a (stub) warehouse feed in parallel. The feed
  always fails after reading the catalogue: a deliberate, reproducible
  failure inside a child task.

  Unlinked tasks (`Task.Supervisor.async_nolink/2`) are used so the crash
  surfaces as an exit from `Task.await/1` in the request process, which
  Phoenix renders as a 500, instead of killing the request process through
  a link.
  """
  def reconcile_inventory do
    local =
      Task.Supervisor.async_nolink(
        TraceGuardDemo.TaskSupervisor,
        TraceGuard.wrap(fn -> list_products() end)
      )

    feed =
      Task.Supervisor.async_nolink(
        TraceGuardDemo.TaskSupervisor,
        TraceGuard.wrap(fn ->
          Repo.aggregate(Product, :sum, :stock)
          raise WarehouseError, "warehouse feed timed out after 3 retries (feed_token=wf_demo_42)"
        end)
      )

    {Task.await(local), Task.await(feed)}
  end

  @audit_lookups 150

  @doc """
  Re-reads products one by one (a deliberate N+1 pattern): #{@audit_lookups}
  single-row queries plus one id query. Used to exceed TraceGuard's default
  100-event buffer.
  """
  def audit_inventory do
    ids = Repo.all(from p in Product, select: p.id, order_by: p.id)

    checked =
      if ids == [] do
        0
      else
        for i <- 0..(@audit_lookups - 1), reduce: 0 do
          acc ->
            Repo.get!(Product, Enum.at(ids, rem(i, length(ids))))
            acc + 1
        end
      end

    %{checked: checked}
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
