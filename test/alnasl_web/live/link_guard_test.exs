defmodule AlnaslWeb.LinkGuardTest do
  @moduledoc """
  Picking a board number that another table already plays: asked first,
  never taken on the change alone (Barco cup, 2026-11-23, round 6 - a select
  stepped through with the keyboard took every board in turn).
  """

  use AlnaslWeb.SiteCase

  @moduletag :capture_log

  defp board(name) do
    {:ok, board} =
      Boards.create(%{name: name, driver: "simulator", options: %{"game" => 1, "speed" => 1}})

    board
  end

  test "a free number links at once; a taken one waits for the arbiter's yes", %{conn: conn} do
    a = board("Table A")
    b = board("Table B")
    {:ok, view, _html} = live(conn, ~p"/boards")

    view |> form("#link-form-#{a.id}", %{board_no: "1"}) |> render_change()
    assert %{round: 1, board_no: 1} = Boards.get!(a.id)
    refute has_element?(view, "#move-request")

    # B passes over board 1 on its way somewhere: A keeps it.
    view |> form("#link-form-#{b.id}", %{board_no: "1"}) |> render_change()
    assert %{board_no: 1} = Boards.get!(a.id)
    assert %{board_no: nil} = Boards.get!(b.id)
    assert has_element?(view, "#move-request", "Table A")

    view |> element("#cancel-move") |> render_click()
    refute has_element?(view, "#move-request")
    assert %{board_no: 1} = Boards.get!(a.id)

    # Asked again, and this time meant.
    view |> form("#link-form-#{b.id}", %{board_no: "1"}) |> render_change()
    view |> element("#confirm-move") |> render_click()
    assert %{round: 1, board_no: 1} = Boards.get!(b.id)
    assert %{board_no: nil} = Boards.get!(a.id)
    refute has_element?(view, "#move-request")
  end
end
