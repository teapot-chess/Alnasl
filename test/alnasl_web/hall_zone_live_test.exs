defmodule AlnaslWeb.HallZoneLiveTest do
  @moduledoc "The hall learns its time zone from the owner's browser, on connect."

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers

  alias Alnasl.Halls

  setup do
    hall = hall_fixture("Annex")
    owner = member(hall, user_fixture("zone-owner@example.org"), "owner")
    viewer = member(hall, user_fixture("zone-viewer@example.org"), "viewer")
    %{hall: hall, owner: owner, viewer: viewer}
  end

  defp open(conn, user, hall, zone) do
    conn = conn |> log_in(user, hall) |> put_connect_params(%{"time_zone" => zone})
    {:ok, view, _html} = live(conn, ~p"/halls/#{hall.id}/settings")
    view
  end

  test "the first owner's browser sets it, a later one does not, a bad name is ignored", ctx do
    %{conn: conn, hall: hall, owner: owner} = ctx
    open(conn, owner, hall, "Not/AZone")
    assert Halls.zone(hall.id) == nil

    view = open(conn, owner, hall, "Europe/Brussels")
    assert Halls.zone(hall.id) == "Europe/Brussels"
    assert has_element?(view, "#hall-zone-value", "Europe/Brussels")
    refute has_element?(view, "#hall-zone-suggestion")

    view = open(conn, owner, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == "Europe/Brussels"
    # The other browser's zone is offered, not applied.
    assert has_element?(view, "#hall-zone-suggestion", "Asia/Tokyo")
  end

  test "the settings page changes it, by select or by the browser suggestion", ctx do
    %{conn: conn, hall: hall, owner: owner} = ctx
    view = open(conn, owner, hall, "Europe/Brussels")

    view |> form("#hall-zone-form", %{"zone" => "America/New_York"}) |> render_submit()
    assert Halls.zone(hall.id) == "America/New_York"
    assert has_element?(view, "#hall-zone-value", "America/New_York")
    assert has_element?(view, "#hall-zone-suggestion", "Europe/Brussels")

    view |> element("#hall-zone-use-browser") |> render_click()
    assert Halls.zone(hall.id) == "Europe/Brussels"

    html = view |> form("#hall-zone-form") |> render_submit(%{"zone" => "Mars/Olympus"})
    assert html =~ "time zone"
    assert Halls.zone(hall.id) == "Europe/Brussels"
  end

  test "an admin visiting does not flip it", ctx do
    %{conn: conn, hall: hall, owner: owner} = ctx
    open(conn, owner, hall, "Europe/Brussels")
    admin = user_fixture("zone-admin@example.org", %{admin: true})
    open(conn, admin, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == "Europe/Brussels"
  end

  test "a viewer's browser does not set it", ctx do
    %{conn: conn, hall: hall, viewer: viewer} = ctx
    view = open(conn, viewer, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == nil
    refute has_element?(view, "#hall-zone-form")

    # Nor can a forged event.
    render_click(view, "set_zone", %{"zone" => "Asia/Tokyo"})
    assert Halls.zone(hall.id) == nil
  end
end
