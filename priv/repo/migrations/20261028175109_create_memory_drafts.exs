defmodule Alnasl.Repo.Migrations.CreateMemoryDrafts do
  use Ecto.Migration

  # A game as a board's own memory has it, where that is not simply more of
  # the game the box has (`Alnasl.BoardHistory`, `Alnasl.MemoryDrafts`):
  # kept beside the game until the arbiter accepts or dismisses it. The
  # digest is what the draft says, so that a memory read twice is one draft.
  def change do
    create table(:memory_drafts) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :board_serial, :string
      add :reason, :string, null: false
      add :start_fen, :string, null: false
      add :from_ply, :integer, null: false, default: 0
      add :plies, :text, null: false, default: "[]"
      add :digest, :string, null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:memory_drafts, [:game_id, :digest])
    create index(:memory_drafts, [:game_id, :status])
  end
end
