defmodule AlnaslWeb.BoardsLiveChessTest do
  @moduledoc """
  A LiveChess board on the Boards page: who LiveChess says is playing,
  why it is on no pairing, and the arbiter's one click that puts it on
  one. The players are made up.
  """

  use AlnaslWeb.SiteCase

  import Alnasl.LinkHelpers

  alias Alnasl.BoardServer

  @moduletag :capture_log

  setup do
    pairing_program()
    {:ok, t: linked(43, name: "Open", boards: 2)}
  end

  defp livechess_board do
    {:ok, board} =
      Boards.create(%{name: "LiveChess#1", driver: "remote", port: "bridge-9:LiveChess#1"})

    eventually(fn -> BoardServer.whereis(board.id) end)
    board
  end

  defp say(board, facts) do
    send(BoardServer.whereis(board.id), {:driver, board.id, {:game, facts}})
    _ = Boards.snapshot(board.id)
  end

  test "on no pairing: why, and a click puts it on one", %{conn: conn, t: t} do
    board = livechess_board()

    say(board, %{
      source: "livechess",
      round: 1,
      game: 1,
      result: "*",
      white: %{name: "Open Player 3"},
      black: %{name: "Nobody Known"}
    })

    eventually(fn ->
      get_in(Boards.snapshot(board.id), [:livechess, :match, :status]) == :none
    end)

    {:ok, view, _html} = live(conn, ~p"/boards")
    assert has_element?(view, "#livechess-players-#{board.id}", "Open Player 3")
    assert has_element?(view, "#livechess-unplaced-#{board.id}")

    pick = "#livechess-pick-#{board.id}-#{t.id}-1-2"
    assert has_element?(view, pick)
    view |> element(pick) |> render_click()

    row = Boards.get!(board.id)
    assert {row.tournament_id, row.round, row.board_no} == {t.id, 1, 2}
    assert has_element?(view, "#livechess-rematch-#{board.id}")
  end

  # The link guard (0.23.1) holds for a LiveChess pick as for the select:
  # a pairing another table plays is asked first.
  test "a pick of a pairing another table plays is asked first", %{conn: conn, t: t} do
    {:ok, dgt} =
      Boards.create(%{
        name: "Table B",
        driver: "simulator",
        options: %{"game" => 1, "speed" => 1}
      })

    {:ok, _} = Boards.update(dgt, %{tournament_id: t.id, round: 1, board_no: 2})
    board = livechess_board()

    say(board, %{
      source: "livechess",
      round: 1,
      game: 1,
      result: "*",
      white: %{name: "Open Player 3"},
      black: %{name: "Nobody Known"}
    })

    eventually(fn ->
      get_in(Boards.snapshot(board.id), [:livechess, :match, :status]) == :none
    end)

    {:ok, view, _html} = live(conn, ~p"/boards")
    view |> element("#livechess-pick-#{board.id}-#{t.id}-1-2") |> render_click()

    assert has_element?(view, "#move-request", "Table B")
    assert %{board_no: 2} = Boards.get!(dgt.id)
    assert %{board_no: nil} = Boards.get!(board.id)

    view |> element("#confirm-move") |> render_click()
    row = Boards.get!(board.id)
    assert {row.tournament_id, row.round, row.board_no} == {t.id, 1, 2}
    assert %{board_no: nil} = Boards.get!(dgt.id)
    refute has_element?(view, "#move-request")
  end

  test "a LiveChess board with no game yet says so", %{conn: conn} do
    board = livechess_board()
    say(board, %{source: "livechess", round: 1, game: 1, result: "*", no_game: true})

    {:ok, view, _html} = live(conn, ~p"/boards")
    assert has_element?(view, "#livechess-no-game-#{board.id}")
  end
end
