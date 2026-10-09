# mix run priv/repo/seeds.exs
alias TraceGuardDemo.Repo
alias TraceGuardDemo.Shop.Product

for {sku, name, price, stock} <- [
      {"TG-001", "Trace Lens", 4_900, 25},
      {"TG-002", "Span Wrench", 1_250, 100}
    ] do
  Repo.insert!(%Product{sku: sku, name: name, price_cents: price, stock: stock},
    on_conflict: :nothing,
    conflict_target: :sku
  )
end
