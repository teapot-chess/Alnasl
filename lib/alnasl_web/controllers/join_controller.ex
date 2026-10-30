defmodule AlnaslWeb.JoinController do
  @moduledoc """
  `/join/<code>`: the one link a bridge needs (`Alnasl.Bridges`).

  `POST` is the bridge redeeming it - who it is in, its own key out, as
  JSON. A used, expired or unknown code is a 410 and nothing more; a bridge
  that speaks another version of the link is a 409, one that is still in
  another hall a 403. `GET` is somebody who
  scanned the code with a phone instead of the bridge: a page that says
  where it goes.

  Codes that do not work are counted per address (`Alnasl.Takeover.RateLimit`):
  after 20 in ten minutes the address gets a 429 with `retry-after` until
  the ten minutes are over. A bridge that joins needs one try.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Bridges
  alias Alnasl.Takeover.RateLimit

  @misses 20
  @window_ms 10 * 60_000

  def redeem(conn, %{"code" => code} = params) do
    key = {:bridge_join, AlnaslWeb.SupportController.client_ip(conn)}

    case RateLimit.peek(key, @misses, @window_ms) do
      :ok ->
        conn = attempt(conn, code, params)
        if conn.status in [400, 410], do: RateLimit.hit(key, @misses, @window_ms)
        conn

      {:error, wait} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(wait))
        |> put_status(429)
        |> json(%{error: "rate_limited"})
    end
  end

  defp attempt(conn, code, params) do
    identity = Map.take(params, ["v", "bridge", "name", "software"])

    case Bridges.redeem(code, identity) do
      {:ok, %{key: key}} ->
        json(conn, %{
          key: key,
          socket: "/bridge/link",
          server: Bridges.server_name(),
          # Whoever could show the link was the hall's owner (or the box
          # had no accounts): that one may make the bridge forget its boards.
          owner: true
        })

      {:error, :version} ->
        conn |> put_status(409) |> json(%{error: "version"})

      {:error, :elsewhere} ->
        conn |> put_status(403) |> json(%{error: "elsewhere"})

      {:error, :bad_request} ->
        conn |> put_status(400) |> json(%{error: "bad_request"})

      {:error, _used_or_expired} ->
        conn |> put_status(410) |> json(%{error: "used_or_expired"})
    end
  end

  def show(conn, %{"code" => code}), do: render(conn, :show, code: code)
end
