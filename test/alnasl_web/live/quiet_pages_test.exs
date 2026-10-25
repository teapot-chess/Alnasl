defmodule AlnaslWeb.QuietPagesTest do
  @moduledoc """
  A page only redraws for news that is its own. The browser of a small box
  pays for every redraw by walking the page again, and one that redrew for
  every board in the hall had no time left to open the board clicked.
  Timing-free: these look at what the page decided, not at a stopwatch.
  """

  use AlnaslWeb.SiteCase

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "a board's page ignores the other boards' moves and keeps its own", %{conn: conn} do
    own = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    other = fake_dgt("FAKE2", %{round: 1, board_no: 2})
    {:ok, view, _html} = live(conn, ~p"/round/1/board/1")
    eventually_html(view, fn _ -> assigns(view).board.id == own.id end)
    # Let whatever the boards said while the page came up run its course.
    eventually_html(view, fn _ -> assigns(view).refresh_due? == false end)

    send(view.pid, {:board, other.id})
    refute assigns(view).refresh_due?

    send(view.pid, {:board, own.id})
    assert assigns(view).refresh_due?
  end

  test "the board is drawn as two shapes, not 64 squares", %{conn: conn} do
    fake_dgt("FAKE1", %{round: 1, board_no: 1})
    {:ok, view, _html} = live(conn, ~p"/round/1/board/1")
    assert has_element?(view, "svg.board path.l")
    refute has_element?(view, "svg.board rect.l")
  end

  test "a burst of outbox news redraws the link once now and once later, not per message",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert assigns(view).link_held == nil

    send(view.pid, :outbox_changed)
    assert assigns(view).link_held == :quiet

    send(view.pid, :outbox_changed)
    send(view.pid, :outbox_changed)
    assert assigns(view).link_held == :again

    send(view.pid, :hall_link_free)
    assert assigns(view).link_held == :quiet

    send(view.pid, :hall_link_free)
    assert assigns(view).link_held == nil
  end
end
