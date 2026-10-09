defmodule TraceGuardDemo.Payments do
  @moduledoc """
  A stub payment gateway client with a deliberate, reproducible failure.

  The demo gateway is permanently "down": every charge raises
  `TraceGuardDemo.Payments.GatewayError`. Its message embeds the merchant API
  key, the way many real client libraries do, so the demo can show that
  TraceGuard scrubs it from the exported report.
  """

  defmodule GatewayError do
    defexception [:message]
  end

  @merchant_api_key "demo_merchant_key_123"

  @spec charge(pos_integer(), map()) :: no_return()
  def charge(amount_cents, _card) do
    raise GatewayError,
      message:
        "card processor returned HTTP 502 for a #{amount_cents} cent charge " <>
          "(merchant api_key=#{@merchant_api_key})"
  end
end
