defmodule AlnaslWeb.LocalStatusControllerTest do
  use AlnaslWeb.ConnCase, async: false

  alias Alnasl.{Repo, Tournaments}
  alias Alnasl.Games.Game

  defp live_game(attrs) do
    t = Tournaments.default()
    {:ok, _} = Tournaments.update(t, %{round: 2})

    Repo.insert!(
      struct!(
        Game,
        Map.merge(
          %{tournament_id: t.id, round: 2, board_no: 1, game_no: 1, local: true, status: "live"},
          attrs
        )
      )
    )
  end

  test "false when nothing is being played", %{conn: conn} do
    conn = get(conn, "/local/status")
    assert json_response(conn, 200) == %{"round_in_progress" => false}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "true while a game of the current round is live", %{conn: conn} do
    live_game(%{})
    assert json_response(get(conn, "/local/status"), 200) == %{"round_in_progress" => true}
  end

  test "finished games and earlier rounds do not count", %{conn: conn} do
    live_game(%{status: "finished", result: "1-0"})
    live_game(%{round: 1, board_no: 2})
    assert json_response(get(conn, "/local/status"), 200) == %{"round_in_progress" => false}
  end

  test "a live game untouched for hours is abandoned, not in progress", %{conn: conn} do
    game = live_game(%{})
    old = DateTime.utc_now() |> DateTime.add(-7 * 3600, :second) |> DateTime.truncate(:second)
    Ecto.Changeset.change(game, updated_at: old) |> Repo.update!()
    assert json_response(get(conn, "/local/status"), 200) == %{"round_in_progress" => false}
  end

  test "refuses a connection from elsewhere", %{conn: conn} do
    conn = %{conn | remote_ip: {192, 168, 1, 20}} |> get("/local/status")
    assert json_response(conn, 403) == %{"error" => "forbidden"}
  end

  test "does not believe forwarding headers, and refuses a proxied request", %{conn: conn} do
    elsewhere = %{conn | remote_ip: {203, 0, 113, 5}}
    c = elsewhere |> put_req_header("x-forwarded-for", "127.0.0.1") |> get("/local/status")
    assert c.status == 403

    c = conn |> put_req_header("cf-connecting-ip", "203.0.113.5") |> get("/local/status")
    assert c.status == 403
  end
end
