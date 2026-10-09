defmodule TraceGuardDemo.Shop.Product do
  use Ecto.Schema

  @derive {Jason.Encoder, only: [:id, :sku, :name, :price_cents, :stock]}
  schema "products" do
    field :sku, :string
    field :name, :string
    field :price_cents, :integer
    field :stock, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
