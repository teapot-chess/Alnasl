defmodule Alnasl.Takeover.State do
  @moduledoc """
  The active box's state as it last sent it (`Alnasl.Takeover.Snapshot`),
  and `mark`: the last event of the hall it already covers. A box taking
  over starts from this and folds in the events after `mark`.
  """

  use Ecto.Schema

  schema "takeover_states" do
    field :hall_id, :integer
    field :box_id, :integer
    field :epoch, :integer
    field :mark, :integer, default: 0
    field :data, :string
    timestamps(type: :utc_datetime)
  end
end
