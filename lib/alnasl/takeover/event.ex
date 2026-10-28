defmodule Alnasl.Takeover.Event do
  @moduledoc """
  One event the active box streamed, as the cloud keeps it. `event_id` is
  the box's name for it and unique in the hall, which is what makes sending
  it twice harmless. `data` is JSON, and only ever data: it is folded into
  games on a box that takes over, never drawn as markup.
  """

  use Ecto.Schema

  schema "takeover_events" do
    field :hall_id, :integer
    field :box_id, :integer
    field :epoch, :integer
    field :event_id, :string
    field :seq, :integer
    field :kind, :string
    field :game, :string
    field :serial, :string
    field :ply, :integer
    field :at, :integer
    field :data, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
