defmodule Alnasl.Repo.Migrations.AddTimeZoneToHalls do
  use Ecto.Migration

  # The hall's own time zone, an IANA name ("Europe/Brussels"), told by the
  # owner's browser (`Alnasl.Zone`). Empty until a browser has said so: the
  # box's own clock stands in meanwhile.
  def change do
    alter table(:halls) do
      add :time_zone, :string
    end
  end
end
