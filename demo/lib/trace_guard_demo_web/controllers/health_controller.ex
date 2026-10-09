defmodule TraceGuardDemoWeb.HealthController do
  use TraceGuardDemoWeb, :controller

  def show(conn, _params), do: json(conn, %{status: "ok"})
end
