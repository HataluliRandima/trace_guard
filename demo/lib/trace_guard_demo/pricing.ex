defmodule TraceGuardDemo.Pricing do
  @moduledoc """
  A long-lived pricing server: the demo's example of explicit GenServer
  trace propagation.

  `use TraceGuard.Server` lets callers that use `TraceGuard.call/3` carry
  their request's trace into `handle_call/3`. Queries the server runs *while
  handling such a call* appear in that request's report, labelled
  `server-N`. Its other work (here, the periodic cache refresh in
  `handle_info/2`) is never attached to any request.

  The "TG-002" quote deliberately fails: the stub currency service raises
  with a message that embeds a credential, which TraceGuard scrubs.
  """

  use GenServer
  use TraceGuard.Server

  import Ecto.Query

  alias TraceGuardDemo.Repo
  alias TraceGuardDemo.Shop.Product

  defmodule CurrencyError do
    defexception [:message]
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Price of `qty` units of `sku`, converted to EUR. Traced for the caller."
  def quote(sku, qty), do: TraceGuard.call(__MODULE__, {:quote, sku, qty})

  @impl true
  def init(:ok) do
    schedule_refresh()
    {:ok, %{rate: 0.92, refreshed: 0}}
  end

  @impl true
  def handle_call({:quote, sku, qty}, _from, state) do
    product = Repo.one(from p in Product, where: p.sku == ^sku)

    reply =
      cond do
        product == nil ->
          {:error, :unknown_sku}

        sku == "TG-002" ->
          raise CurrencyError,
                "currency service rejected conversion (rate_api_token=rt_demo_secret_77)"

        true ->
          {:ok, %{sku: sku, qty: qty, eur_cents: round(product.price_cents * qty * state.rate)}}
      end

    {:reply, reply, state}
  end

  # Background work: never part of a request's trace.
  @impl true
  def handle_info(:refresh, state) do
    _ = Repo.aggregate(Product, :count)
    schedule_refresh()
    {:noreply, %{state | refreshed: state.refreshed + 1}}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, 60_000)
end
