defmodule AlnaslWeb.BoardDebugLogTest do
  @moduledoc """
  The board debug log beside the board on its page: there only when Setup
  says so, only for whoever may arbitrate there, live, and filtered.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{BoardLog, Halls}

  setup do
    BoardLog.clear_all()
    on_exit(&BoardLog.clear_all/0)
    :ok
  end

  describe "on a box without accounts" do
    test "off by default; on, it shows the board's lines and new ones as they come", %{
      conn: conn
    } do
      board = fake_dgt("FAKE1", %{round: 1, board_no: 2})
      eventually(fn -> Boards.snapshot(board.id).status == :waiting_start end)

      {:ok, view, _html} = live(conn, ~p"/round/1/board/2")
      refute has_element?(view, "#debug-log")

      Settings.put("board_debug_log", true)
      eventually_html(view, fn _ -> has_element?(view, "#debug-log-lines") end)
      assert has_element?(view, "#debug-log-lines .debug-line")
      assert has_element?(view, "#debug-cat-all[aria-pressed=true]")

      play_on("FAKE1", board.id, ~w(e4))
      eventually_html(view, &(&1 =~ "e4 recognised"))

      # Results only: no moves.
      view |> element("#debug-cat-result") |> render_click()
      assert has_element?(view, "#debug-cat-result[aria-pressed=true]")
      refute render(view) =~ "e4 recognised"

      view |> element("#debug-cat-move") |> render_click()
      assert render(view) =~ "e4 recognised"

      Settings.put("board_debug_log", false)
      eventually_html(view, fn _ -> not has_element?(view, "#debug-log") end)
    end

    test "Setup > Advanced switches it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/advanced")
      assert has_element?(view, "#setup-debug-log")

      view
      |> form("#debug-log-form", debug: %{board_debug_log: "true"})
      |> render_change()

      assert Settings.get("board_debug_log") == true
    end
  end

  describe "with accounts" do
    setup do
      _admin = first_owner()
      hall = hall_fixture("Hall A")
      tournament = Halls.local_tournament(hall)

      {:ok, board} =
        Boards.create(%{
          name: "A-1",
          driver: "remote",
          port: "bridge-0:A-1",
          hall_id: hall.id,
          tournament_id: tournament.id,
          round: 1,
          board_no: 1
        })

      BoardLog.add(board.id, :result, "result.by_hand", %{result: "1-0", by: "arbiter"})
      Settings.put("board_debug_log", true)
      %{hall: hall, tournament: tournament, board: board}
    end

    test "an arbiter of the hall sees it", %{conn: conn, hall: hall, tournament: t} do
      user = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      {:ok, view, _html} = live(log_in(conn, user, hall), ~p"/t/#{t.id}/round/1/board/1")
      assert has_element?(view, "#debug-log")
      assert render(view) =~ "set by the arbiter on the board"
    end

    test "a viewer does not, and cannot ask for it", %{conn: conn, hall: hall, tournament: t} do
      user = member(hall, user_fixture("viewer@example.org"), "viewer")
      {:ok, view, _html} = live(log_in(conn, user, hall), ~p"/t/#{t.id}/round/1/board/1")
      refute has_element?(view, "#debug-log")
      refute render(view) =~ "set by the arbiter on the board"

      render_hook(view, "debug_filter", %{"cat" => "result"})
      refute has_element?(view, "#debug-log")
    end
  end
end
