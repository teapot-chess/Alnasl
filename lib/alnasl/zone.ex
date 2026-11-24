defmodule Alnasl.Zone do
  @moduledoc """
  A hall's time zone: an IANA name such as `"Europe/Brussels"`, taken from
  the owner's browser and kept on the hall (`halls.time_zone`).

  Without one (`nil`) everything is the box's own local time, as it was
  before halls had zones. That is right on a Pi whose operating system is set
  to the hall's zone, and wrong on a hosted server, which keeps UTC - hence
  the zone.

  Names are checked against the time zone database (`Tz`, configured as
  Elixir's `:time_zone_database`) before they are kept; nothing from a
  browser is trusted, and nothing is turned into an atom.
  """

  @max_length 64

  @doc "Is `zone` a time zone the database knows?"
  def valid?(zone) when is_binary(zone) and byte_size(zone) in 1..@max_length do
    String.match?(zone, ~r/\A[A-Za-z0-9_+\-\/]+\z/) and match?({:ok, _}, DateTime.now(zone))
  end

  def valid?(_other), do: false

  @doc "`zone` when valid, else `nil`."
  def clean(zone), do: if(valid?(zone), do: zone)

  @doc "Now on the wall clock of `zone`, as a naive time (the box's own with `nil`)."
  def local_now(nil), do: NaiveDateTime.local_now()

  def local_now(zone) do
    case DateTime.now(zone) do
      {:ok, now} -> DateTime.to_naive(now)
      _unknown -> NaiveDateTime.local_now()
    end
  end

  @doc "`at` (UTC) on the wall clock of `zone` (the box's own with `nil`)."
  def shift(%DateTime{} = at, zone) when is_binary(zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _unknown -> shift(at, nil)
    end
  end

  def shift(%DateTime{} = at, nil) do
    {{y, mo, d}, {h, mi, s}} =
      :calendar.universal_time_to_local_time(
        {{at.year, at.month, at.day}, {at.hour, at.minute, at.second}}
      )

    %{at | year: y, month: mo, day: d, hour: h, minute: mi, second: s}
  end
end
