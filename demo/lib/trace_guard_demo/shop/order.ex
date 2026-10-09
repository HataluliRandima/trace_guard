defmodule TraceGuardDemo.Shop.Order do
  use Ecto.Schema

  schema "orders" do
    belongs_to :product, TraceGuardDemo.Shop.Product
    field :quantity, :integer
    field :total_cents, :integer
    field :status, :string
    timestamps(type: :utc_datetime)
  end
end
