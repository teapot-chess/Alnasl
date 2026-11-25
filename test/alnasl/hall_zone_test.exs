defmodule Alnasl.HallZoneTest do
  @moduledoc """
  A hall's time zone: told by the owner's browser, checked against the
  database, and used for what the pages show.
  """

  use Alnasl.DataCase, async: false

  alias Alnasl.{Accounts, Halls, Zone}
  alias Alnasl.Halls.Hall
  alias AlnaslWeb.Words

  setup do
    on_exit(fn -> Words.put_zone(nil) end)
    hall = Halls.own()
    %{hall: hall, scope: Accounts.scope(nil, hall.id)}
  end

  test "the first zone an owner's browser reports is kept", %{hall: hall, scope: scope} do
    assert hall.time_zone == nil
    assert Halls.note_zone(scope, hall, "Europe/Brussels") == "Europe/Brussels"
    assert Halls.zone(hall.id) == "Europe/Brussels"
  end

  test "a later browser in another zone does not overwrite it", %{hall: hall, scope: scope} do
    Halls.note_zone(scope, hall, "Europe/Brussels")
    hall = Repo.get!(Hall, hall.id)
    assert Halls.note_zone(scope, hall, "America/New_York") == "Europe/Brussels"
    # Not even with a stale copy of the hall that still thinks it has no zone.
    stale = %{hall | time_zone: nil}
    assert Halls.note_zone(scope, stale, "Asia/Tokyo") == "Europe/Brussels"
    assert Halls.zone(hall.id) == "Europe/Brussels"
  end

  test "setting it on purpose changes it, owners only, known names only", %{
    hall: hall,
    scope: scope
  } do
    Halls.note_zone(scope, hall, "Europe/Brussels")
    hall = Repo.get!(Hall, hall.id)

    assert {:error, :forbidden} = Halls.set_zone(nil, hall, "Asia/Tokyo")
    assert {:error, :invalid} = Halls.set_zone(scope, hall, "Mars/Olympus")
    assert Halls.zone(hall.id) == "Europe/Brussels"

    assert {:ok, %Hall{time_zone: "Asia/Tokyo"}} = Halls.set_zone(scope, hall, "Asia/Tokyo")
    assert Halls.zone(hall.id) == "Asia/Tokyo"
  end

  test "a name the database does not know, or no name, changes nothing", %{
    hall: hall,
    scope: scope
  } do
    Halls.note_zone(scope, hall, "Europe/Brussels")
    hall = Repo.get!(Hall, hall.id)

    for bad <- ["Mars/Olympus", "", "../etc/passwd", String.duplicate("A", 200), nil, 42] do
      assert Halls.note_zone(scope, hall, bad) == "Europe/Brussels"
    end

    assert Halls.zone(hall.id) == "Europe/Brussels"
  end

  test "nobody but an owner of the hall tells its zone", %{hall: hall} do
    assert Halls.note_zone(nil, hall, "Europe/Brussels") == nil
    assert Halls.zone(hall.id) == nil
    assert Halls.zone(nil) == nil
  end

  test "Words shows times in the hall's zone, the box's own without one" do
    at = ~U[2026-07-01 12:00:00Z]

    Words.put_zone("Asia/Tokyo")
    assert Words.time(at) == "21:00:00"
    assert Words.hm(at) == "21:00"
    assert Words.datetime(at) == "2026-07-01 21:00"

    Words.put_zone("Europe/Brussels")
    assert Words.time(at) == "14:00:00"
    # Winter time, same zone.
    assert Words.datetime(~U[2026-12-01 12:00:00Z]) == "2026-12-01 13:00"

    # The date can change with the zone.
    Words.put_zone("Pacific/Kiritimati")
    assert Words.date(~U[2026-07-01 12:00:00Z]) == "2026-07-02"

    Words.put_zone(nil)
    assert Words.time(at) == Calendar.strftime(Zone.shift(at, nil), "%H:%M:%S")
  end

  test "Zone.local_now is the wall clock of the zone" do
    far_ahead = Zone.local_now("Pacific/Kiritimati")
    far_behind = Zone.local_now("Pacific/Pago_Pago")
    assert NaiveDateTime.diff(far_ahead, far_behind, :hour) in 24..25
    assert Zone.local_now("Nowhere/Land") |> is_struct(NaiveDateTime)
    assert Zone.clean("Europe/Brussels") == "Europe/Brussels"
    assert Zone.clean("Nowhere/Land") == nil
  end
end
