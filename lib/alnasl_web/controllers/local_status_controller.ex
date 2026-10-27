defmodule AlnaslWeb.LocalStatusController do
  @moduledoc """
  `GET /local/status`: what the box's own helpers may ask Alnasl, and nobody else.

  Answers `{"round_in_progress": true | false}`, where true is
  `Alnasl.Games.in_progress?/0`: a game of the tournament's current round is
  still live on this box. The nightly OS update asks before it touches
  anything, and puts itself off a night when the answer is true.

  Loopback only. The check is the address of the connection itself
  (`conn.remote_ip`). Forwarding headers are never believed; their mere
  presence is a reason to refuse, because a request that came through a
  proxy or tunnel (which connects from the loopback address) carries one,
  and a helper on the box does not.
  """

  use AlnaslWeb, :controller

  def show(conn, _params) do
    if loopback?(conn.remote_ip) and not forwarded?(conn) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{round_in_progress: Alnasl.Games.in_progress?()})
    else
      conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  @forwarding ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host)
  defp forwarded?(conn), do: Enum.any?(@forwarding, &(get_req_header(conn, &1) != []))

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_other), do: false
end
