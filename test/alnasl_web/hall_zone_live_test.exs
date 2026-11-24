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

  test "an owner's browser sets it, a later one changes it, a bad name is ignored", ctx do
    %{conn: conn, hall: hall, owner: owner} = ctx
    view = open(conn, owner, hall, "Europe/Brussels")
    assert Halls.zone(hall.id) == "Europe/Brussels"
    assert render(view) =~ "Europe/Brussels"
    assert has_element?(view, "#hall-zone-value", "Europe/Brussels")

    open(conn, owner, hall, "Not/AZone")
    assert Halls.zone(hall.id) == "Europe/Brussels"

    open(conn, owner, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == "Asia/Tokyo"
  end

  test "a viewer's browser does not set it", ctx do
    %{conn: conn, hall: hall, viewer: viewer} = ctx
    open(conn, viewer, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == nil
  end
end
