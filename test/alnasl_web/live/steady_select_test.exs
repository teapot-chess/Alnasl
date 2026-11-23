defmodule AlnaslWeb.SteadySelectTest do
  @moduledoc """
  The Boards page's selects under the re-renders a hall full of boards
  causes (2026-11-23, tournament 311: the board-of-the-round select shut
  after half a second and the choice was lost). The select is kept out of
  LiveView's patches; what the server says rides on the wrapper's data
  attributes. The browser half is test/e2e/boards_select_test.exs.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.Tournaments

  @moduletag :capture_log

  setup do
    document = %{
      "players" => [],
      "rounds" => [
        %{"number" => 1, "boards" => for(n <- 1..3, do: %{"board" => n, "kind" => "game"})}
      ]
    }

    Tournaments.update!(Tournaments.default(), %{document: Jason.encode!(document)})

    {:ok, board} =
      Boards.create(%{
        name: "Table A",
        driver: "simulator",
        options: %{"game" => 1, "speed" => 20}
      })

    %{board: board}
  end

  # What the page gets from a board many times a second, and the reload it
  # leads to.
  defp churn(view, board) do
    for _ <- 1..3 do
      send(view.pid, {:board, board.id})
      send(view.pid, :refresh)
    end

    _ = render(view)
  end

  test "a choice saves while the page re-renders, and the select is never patched", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/boards")
    box = "#link-#{board.id}-box"

    assert has_element?(view, "#{box}[phx-update=ignore][phx-hook]")
    assert has_element?(view, "#{box}[data-value='']")

    churn(view, board)
    view |> form("#link-form-#{board.id}", %{board_no: "2"}) |> render_change()
    assert %{round: 1, board_no: 2} = Boards.get!(board.id)

    churn(view, board)
    assert has_element?(view, "#{box}[data-value='2']")
    assert has_element?(view, "#{box}[data-options*='board 3']")

    # Moved under it by someone else: the select is left alone, the data
    # attribute says the new number for the hook to put in.
    Boards.link(Boards.get!(board.id), 1, 3)
    churn(view, board)
    assert has_element?(view, "#{box}[data-value='3']")
    # The select itself is still the markup it was first drawn with.
    assert has_element?(view, "#link-#{board.id} option[value=''][selected]")
  end

  test "the tournament select is kept the same way", %{conn: conn, board: board} do
    Alnasl.Repo.insert!(%Tournaments.Tournament{
      kind: "linked",
      name: "Second open",
      label: "Second open"
    })

    {:ok, view, _html} = live(conn, ~p"/boards")
    assert has_element?(view, "#tournament-#{board.id}-box[phx-update=ignore]")
    churn(view, board)
    assert has_element?(view, "#tournament-#{board.id}-box[data-value='#{board.tournament_id}']")
  end
end
