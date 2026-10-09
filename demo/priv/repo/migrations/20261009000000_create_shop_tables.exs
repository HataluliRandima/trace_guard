defmodule TraceGuardDemo.Repo.Migrations.CreateShopTables do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :sku, :string, null: false
      add :name, :string, null: false
      add :price_cents, :integer, null: false
      add :stock, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:products, [:sku])

    create table(:orders) do
      add :product_id, references(:products), null: false
      add :quantity, :integer, null: false
      add :total_cents, :integer, null: false
      add :status, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
