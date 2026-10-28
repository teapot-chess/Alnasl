defmodule Alnasl.Takeover.Join do
  @moduledoc "A pairing code for a box: shown once, good for fifteen minutes and one box."

  use Ecto.Schema

  schema "takeover_joins" do
    field :code, :string
    field :hall_id, :integer
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :box_id, :integer
    timestamps(type: :utc_datetime)
  end
end
