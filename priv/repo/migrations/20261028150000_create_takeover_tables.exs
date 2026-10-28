defmodule Alnasl.Repo.Migrations.CreateTakeoverTables do
  use Ecto.Migration

  # A spare box taking over a hall (`Alnasl.Takeover`, docs/takeover.md).
  # New tables only: nothing that is already in a database is touched, so an
  # installation with years of games in it migrates in a blink.
  def change do
    # --- the cloud's side -------------------------------------------------------

    # A box paired with a hall: its own long key, hashed.
    create table(:takeover_boxes) do
      add :hall_id, :integer, null: false
      add :uid, :string, null: false
      add :name, :string
      add :software, :string
      add :key_hash, :string, null: false
      add :role, :string
      add :queued, :integer, null: false, default: 0
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:takeover_boxes, [:uid])
    create index(:takeover_boxes, [:hall_id])

    # A pairing code: shown once, good for fifteen minutes and one box.
    create table(:takeover_joins) do
      add :code, :string, null: false
      add :hall_id, :integer, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :box_id, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:takeover_joins, [:code])

    # Who runs a hall: one box, one epoch, until it goes quiet.
    create table(:takeover_leases) do
      add :hall_id, :integer, null: false
      add :box_id, :integer
      add :epoch, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :granted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:takeover_leases, [:hall_id])

    # What the active box streamed: append-only, one row an event.
    create table(:takeover_events) do
      add :hall_id, :integer, null: false
      add :box_id, :integer, null: false
      add :epoch, :integer, null: false
      add :event_id, :string, null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :game, :string
      add :serial, :string
      add :ply, :integer
      add :at, :integer
      add :data, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:takeover_events, [:hall_id, :event_id])
    create index(:takeover_events, [:hall_id, :id])

    # The box's state as it last sent it, and the last event it had covered.
    create table(:takeover_states) do
      add :hall_id, :integer, null: false
      add :box_id, :integer, null: false
      add :epoch, :integer, null: false
      add :mark, :integer, null: false, default: 0
      add :data, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:takeover_states, [:hall_id])

    # --- the box's side ---------------------------------------------------------

    # Events waiting for the cloud. The id is the event's number for good:
    # AUTOINCREMENT, never reused, so a number the cloud has seen is never
    # somebody else's after the queue was emptied.
    create table(:takeover_queue) do
      add :kind, :string, null: false
      add :game, :string
      add :serial, :string
      add :ply, :integer
      add :at, :integer
      add :data, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
