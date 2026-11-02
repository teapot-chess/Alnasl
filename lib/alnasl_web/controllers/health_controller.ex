defmodule AlnaslWeb.HealthController do
  @moduledoc """
  `GET /healthz`: 200 and `"status": "ok"` when the database answers, 503 and
  `"degraded"` when it does not. See `Alnasl.Ops.Health` for what is in the
  body and why so little.

  Routed outside every pipeline: no session, no CSRF, no locale, no PIN, no
  sign-in, and no log line (`log: false` on the route, and
  `AlnaslWeb.Endpoint.log_level/1` for the endpoint's own). Never cached.
  """
  use AlnaslWeb, :controller

  alias Alnasl.Ops.Health

  def show(conn, _params) do
    # The report can be handed in by a test (`conn.assigns.health_report`);
    # nothing on the route sets it.
    report = conn.assigns[:health_report] || Health.report()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if report.status == "ok", do: 200, else: 503)
    |> json(report)
  end
end
