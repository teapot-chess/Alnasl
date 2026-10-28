defmodule Alnasl.Takeover.Queued do
  @moduledoc """
  An event waiting on this box for the cloud (`Alnasl.Takeover.Stream`).
  `id` is its number for good - the table's key is AUTOINCREMENT, so it is
  never reused - and the cloud knows it as `"<box uid>-<id>"`.
  """

  use Ecto.Schema

  schema "takeover_queue" do
    field :kind, :string
    field :game, :string
    field :serial, :string
    field :ply, :integer
    field :at, :integer
    field :data, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
