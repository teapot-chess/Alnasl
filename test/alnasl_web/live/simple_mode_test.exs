defmodule AlnaslWeb.SimpleModeTest do
  @moduledoc """
  Simple mode (`AlnaslWeb.Mode`, docs/simple-mode.md): what a new
  installation starts with, the pages it leaves out of the menu, the calm
  notice a link to one of them shows, and the switch - kept for the box
  without accounts, and per account with them.
  """

  use AlnaslWeb.SiteCase, async: false

  import AlnaslWeb.AccountHelpers

  alias Alnasl.{Accounts, Halls, Repo, Settings}
  alias Alnasl.Accounts.User
  alias AlnaslWeb.Mode

  # A new installation: no "ui_mode" written (`Alnasl.DataCase`).
  @moduletag :simple_mode

  # The places simple mode keeps, and the ones that are full mode's.
  @kept ~w(round boards halls setup help)
  @hidden ~w(pgn outbox log recordings)

  # Full-mode pages, by address, as somebody might have bookmarked them.
  @hidden_paths ["/pgn", "/outbox", "/log", "/recordings", "/boards/find", "/setup/advanced"]

  describe "a box without accounts" do
    test "starts in simple mode: the basic places, and the switch", %{conn: conn} do
      assert Mode.installation() == "simple"

      {:ok, view, _html} = live(conn, ~p"/")

      for key <- @kept, do: assert(has_element?(view, "#nav #nav-#{key}"))

      for key <- @hidden do
        refute has_element?(view, "#nav-#{key}")
        refute has_element?(view, "#tab-bar #tab-#{key}")
      end

      assert has_element?(view, "#nav-show-everything")
      assert has_element?(view, "#tab-show-everything")
      assert has_element?(view, "#mode-switch[aria-checked=false]")
      # Theme packs are full mode's; the built-in themes are not.
      assert has_element?(view, "#theme-picker [data-theme-opt=paper]")
    end

    test "a full-mode page by its address shows the notice, not the page", %{conn: conn} do
      for path <- @hidden_paths do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "#full-mode-notice"), path
        assert has_element?(view, "#full-mode-switch[phx-value-mode=full]"), path
        assert has_element?(view, "#full-mode-back[href='/']"), path
      end
    end

    test "the basic pages are themselves", %{conn: conn} do
      for path <- ["/", "/boards", "/boards/number", "/halls", "/setup/connections", "/help"] do
        {:ok, view, _html} = live(conn, path)
        refute has_element?(view, "#full-mode-notice"), path
      end
    end

    test "Setup lists only its basic sections, and the rest still opens by address",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connections")

      for slug <- ~w(wizard tournaments connections),
          do: assert(has_element?(view, "#setup-nav-#{slug}"))

      for slug <- ~w(results this-box access advanced),
          do: refute(has_element?(view, "#setup-nav-#{slug}"))
    end

    test "the switch opens the page in place, and the box keeps it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/outbox")
      assert has_element?(view, "#full-mode-notice")

      view |> element("#full-mode-switch") |> render_click()

      refute has_element?(view, "#full-mode-notice")
      assert has_element?(view, "#nav-outbox")
      assert has_element?(view, "#mode-switch[aria-checked=true]")
      refute has_element?(view, "#nav-show-everything")
      assert Settings.get("ui_mode") == "full"

      # A new page, as another browser of the hall would open it.
      {:ok, again, _html} = live(build_conn(), ~p"/log")
      refute has_element?(again, "#full-mode-notice")
      for key <- @hidden, do: assert(has_element?(again, "#nav-#{key}"))
    end

    test "and back to simple mode from the account menu", %{conn: conn} do
      Settings.put("ui_mode", "full")
      {:ok, view, _html} = live(conn, ~p"/recordings")
      refute has_element?(view, "#full-mode-notice")

      view |> element("#mode-switch") |> render_click()

      assert has_element?(view, "#full-mode-notice")
      refute has_element?(view, "#nav-recordings")
      assert Settings.get("ui_mode") == "simple"
    end

    test "full mode shows every place", %{conn: conn} do
      Settings.put("ui_mode", "full")
      {:ok, view, _html} = live(conn, ~p"/")

      for key <- @kept ++ @hidden, do: assert(has_element?(view, "#nav-#{key}"))
      assert has_element?(view, "#tab-bar #tab-outbox")
      refute has_element?(view, "#nav-show-everything")

      for path <- @hidden_paths do
        {:ok, page, _html} = live(conn, path)
        refute has_element?(page, "#full-mode-notice"), path
      end
    end

    test "a results badge in simple mode is not a way into the outbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#link-state a[href='/outbox']")
    end

    test "the tab bar follows the mode: Results only in full mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tab-bar > #tab-round")
      assert has_element?(view, "#tab-bar > #tab-boards")
      refute has_element?(view, "#tab-bar #tab-outbox")

      render_click(view, "ui_mode", %{"mode" => "full"})
      assert has_element?(view, "#tab-bar > #tab-outbox")
    end
  end

  # The small screen's layout is CSS (test/e2e/compact_test.exs measures
  # it); what it needs from the page is said here.
  describe "for the small-screen layout" do
    test "the list of halls carries its headings into each cell, for the cards", %{conn: conn} do
      id = Halls.own_id()
      {:ok, view, _html} = live(conn, ~p"/halls")

      assert has_element?(view, "#halls.cards")
      assert has_element?(view, "#hall-#{id}-role[data-label='Your role']")
      assert has_element?(view, "#hall-#{id}-boards[data-label='Live boards']")
      assert has_element?(view, "#hall-#{id}-bridges[data-label='Bridges']")
    end
  end

  describe "with accounts" do
    setup do
      owner = first_owner()
      viewer = user_fixture("viewer@example.org")
      member(Halls.own(), viewer, "viewer")
      %{owner: owner, viewer: viewer}
    end

    test "each account keeps its own choice", %{conn: conn, owner: owner, viewer: viewer} do
      {:ok, view, _html} = live(log_in(conn, owner), ~p"/pgn")
      assert has_element?(view, "#full-mode-notice")

      view |> element("#full-mode-switch") |> render_click()
      refute has_element?(view, "#full-mode-notice")

      assert Repo.get!(User, owner.id).ui_mode == "full"
      # The installation is left as it was, and so is everybody else.
      assert Mode.installation() == "simple"

      {:ok, again, _html} = live(log_in(build_conn(), owner), ~p"/pgn")
      refute has_element?(again, "#full-mode-notice")

      {:ok, theirs, _html} = live(log_in(build_conn(), viewer), ~p"/pgn")
      assert has_element?(theirs, "#full-mode-notice")
    end

    test "a viewer may switch: it is about what they see, not what they change",
         %{conn: conn, viewer: viewer} do
      {:ok, view, _html} = live(log_in(conn, viewer), ~p"/")

      view |> element("#mode-switch") |> render_click()

      assert has_element?(view, "#nav-pgn")
      assert Repo.get!(User, viewer.id).ui_mode == "full"
    end

    test "an account without a choice follows the installation", %{owner: owner} do
      Settings.put("ui_mode", "full")
      scope = Accounts.scope(Repo.get!(User, owner.id), nil)
      assert Mode.mode(scope) == "full"

      {:ok, user} = Accounts.set_ui_mode(owner, "simple")
      assert Mode.mode(Accounts.scope(user, nil)) == "simple"
    end
  end

  describe "the tour" do
    test "walks only the pages simple mode shows" do
      who = %{role: "owner", fair_play?: true, hall_id: Halls.own_id()}

      assert "results" in AlnaslWeb.Tour.keys(who)
      refute "results" in AlnaslWeb.Tour.keys(Map.put(who, :simple?, true))
      refute "fair_play" in AlnaslWeb.Tour.keys(Map.put(who, :simple?, true))
    end
  end

  test "which addresses are full mode's" do
    for path <- @hidden_paths ++ ["/fair-play", "/halls/1/fair-play", "/support", "/outbox?x=1"],
        do: assert(Mode.full_only?(path), path)

    for path <-
          ["/", "/boards", "/boards/number", "/round/2/board/3", "/halls/1/bridges"] ++
            ["/setup", "/setup/wizard", "/setup/updates", "/help/fair-play"],
        do: refute(Mode.full_only?(path), path)
  end
end
