defmodule Alnasl.Takeover.Lease do
  @moduledoc """
  Who runs a hall: `box_id`, for this `epoch`, until `expires_at` unless it
  says so again. Every grant to another box is a new epoch; a write that
  carries an older one is refused (`Alnasl.Takeover.Cloud`).
  """

  use Ecto.Schema

  schema "takeover_leases" do
    field :hall_id, :integer
    field :box_id, :integer
    field :epoch, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :granted_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
