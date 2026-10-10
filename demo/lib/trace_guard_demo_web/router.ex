defmodule TraceGuardDemoWeb.Router do
  use TraceGuardDemoWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", TraceGuardDemoWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/products", ProductController, :index
    get "/catalog", ProductController, :catalog
    get "/catalog/parallel", ProductController, :catalog_parallel
    get "/inventory/audit", InventoryController, :audit
    post "/checkout", CheckoutController, :create
    post "/inventory/sync", InventoryController, :sync
    post "/inventory/reconcile", InventoryController, :reconcile
    post "/quote", QuoteController, :create
  end

  # Diagnostic reports are for developers only; never expose them in production.
  if Application.compile_env(:trace_guard_demo, :expose_trace_reports, false) do
    scope "/dev/traces", TraceGuardDemoWeb do
      pipe_through :api

      get "/", TraceReportController, :index
      get "/:trace_id", TraceReportController, :show
    end
  end
end
