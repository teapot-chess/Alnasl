defmodule Alnasl.Takeover.Box do
  @moduledoc """
  The cloud's record of a hall box paired with one of its halls
  (`Alnasl.Takeover.Cloud`): what it calls itself (`uid`), the hash of its
  key, and what it last said - the role it believes it has, how much it has
  queued, when it was last heard from. `revoked_at` is set when the hall's
  owner removes it; the row stays, so that the box is told so instead of
  merely being turned away.
  """

  use Ecto.Schema

  schema "takeover_boxes" do
    field :hall_id, :integer
    field :uid, :string
    field :name, :string
    field :software, :string
    field :key_hash, :string, redact: true
    field :role, :string
    field :queued, :integer, default: 0
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
