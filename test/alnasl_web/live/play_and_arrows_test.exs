defmodule AlnaslWeb.PlayAndArrowsTest do
  @moduledoc """
  Repairing a game without typing: the candidates of a guess as arrows on
  one board, picked with a tap; and a move played on the board - a piece,
  then where it goes - instead of spelled out.
  """

  use AlnaslWeb.SiteCase

  # A game as the box holds it, on a board that reads its last position.
  defp game_on_board(conn, sans, flags) do
    game = Games.ensure(1, 3, %{})

    plies =
      sans
      |> Enum.with_index()
      |> Enum.map(fn {san, index} -> %{san: san, flags: flags.(index), clock: nil} end)

    Games.apply_event(game, {:moves, plies}, System.os_time(:millisecond))

    board = fake_dgt("FAKE1")
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    set_pieces("FAKE1", List.last(boards_after(sans)))

    eventually(fn ->
      Boards.snapshot(board.id).raw == Position.to_text(List.last(boards_after(sans)))
    end)

    {:ok, _} = Boards.link(board, 1, 3)
    eventually(fn -> Boards.snapshot(board.id).status in [:live, :recovered] end)
    {:ok, view, _html} = live(conn, ~p"/round/1/board/3")
    {board, view}
  end

  defp tap_on(view, square), do: view |> element("#play-#{square}") |> render_click()

  describe "the candidates as arrows" do
    setup %{conn: conn} do
      {board, view} =
        game_on_board(conn, ~w(e4 Nc6 Nc3 Nf6 d3 e5 d4 Ba3 dxe5 Bf8), fn index ->
          if index >= 6, do: [:guessed, :alone, :long_gap], else: []
        end)

      view |> element("#review-guess") |> render_click()
      {:ok, board: board, view: view}
    end

    test "one board, an arrow per candidate, numbered as in the list, the likeliest solid", %{
      view: view
    } do
      assert has_element?(view, "#choice-arrows")
      assert has_element?(view, "#choice-arrow-0.primary")
      assert has_element?(view, "#choice-arrow-1")
      refute has_element?(view, "#choice-arrow-1.primary")
      assert has_element?(view, "#choice-arrow-0 .arrow-n", "1")
      assert has_element?(view, "#choice-arrow-1 .arrow-n", "2")
      assert has_element?(view, "#choice-option-0 .arrow-key", "1")
      assert has_element?(view, "#choice-option-1 .arrow-key", "2")
    end

    test "a tap on an arrow answers the question, as the list does", %{view: view, board: board} do
      view |> element("#choice-arrow-0") |> render_click()
      assert has_element?(view, "#choice-answer")
      view |> element("#choice-apply") |> render_click()
      assert sans(board.id) == ~w(e4 Nc6 Nc3 Nf6 d4 e5 dxe5)
    end

    test "the other arrow picks the other move", %{view: view} do
      view |> element("#choice-arrow-1") |> render_click()
      assert has_element?(view, "#choice-settled .choice-san", "d3")
    end
  end

  describe "playing a move on the board" do
    setup %{conn: conn} do
      {board, view} = game_on_board(conn, ~w(e4 e5), fn _index -> [] end)
      {:ok, board: board, view: view}
    end

    test "a piece, then a legal square: the move is in the field, and added with the button", %{
      view: view,
      board: board
    } do
      assert has_element?(view, "#play-board")
      tap_on(view, "g1")
      assert has_element?(view, "#play-board .tap-sel")
      assert has_element?(view, "#play-board .tap-dot")
      tap_on(view, "f3")

      assert has_element?(view, "#typed-moves[value='Nf3']")
      # Black to move now, on the board that shows it.
      tap_on(view, "b8")
      tap_on(view, "c6")
      assert has_element?(view, "#typed-moves[value='Nf3 Nc6']")

      view |> element("#play-back") |> render_click()
      assert has_element?(view, "#typed-moves[value='Nf3']")

      # The pieces on the board as they stand after it, as in the hall.
      after_it = List.last(boards_after(~w(e4 e5 Nf3)))
      set_pieces("FAKE1", after_it)
      eventually(fn -> Boards.snapshot(board.id).raw == Position.to_text(after_it) end)

      assert view |> element("#play-commit") |> render_click() =~ "1 move(s) added"
      assert sans(board.id) == ~w(e4 e5 Nf3)
    end

    test "an illegal square is refused, and nothing is added", %{view: view, board: board} do
      tap_on(view, "g1")
      tap_on(view, "g4")
      assert has_element?(view, "#play-note")
      assert has_element?(view, "#typed-moves[value='']")
      refute has_element?(view, "#play-commit")

      # Put down again; the other side's piece is not picked up at all.
      tap_on(view, "g1")
      refute has_element?(view, "#play-board .tap-sel")
      tap_on(view, "e5")
      assert has_element?(view, "#play-note")
      refute has_element?(view, "#play-board .tap-sel")
      assert sans(board.id) == ~w(e4 e5)
    end

    test "changing a move: the board is the position that move is played in", %{
      view: view,
      board: board
    } do
      view
      |> form("#edit-move-form", edit: %{ply: "2", san: ""})
      |> render_change()

      assert has_element?(view, "#play-on-edit[aria-pressed='true']")
      tap_on(view, "c7")
      tap_on(view, "c5")
      assert has_element?(view, "#edit-san[value='c5']")
      view |> element("#play-commit") |> render_click()
      assert sans(board.id) == ~w(e4 c5)
    end

    test "a pawn on the last rank asks which piece it becomes", %{view: view, board: board} do
      :ok = Boards.set_fen(board.id, "7k/P7/8/8/8/8/8/K7 w - - 0 1")
      eventually_html(view, fn _ -> not has_element?(view, "#move-list") end)

      tap_on(view, "a7")
      tap_on(view, "a8")
      assert has_element?(view, "#play-promo")
      assert has_element?(view, "#play-promo-q")
      refute has_element?(view, "#typed-moves[value='a8=Q']")

      view |> element("#play-promo-n") |> render_click()
      refute has_element?(view, "#play-promo")
      assert has_element?(view, "#typed-moves[value='a8=N']")
    end
  end
end
