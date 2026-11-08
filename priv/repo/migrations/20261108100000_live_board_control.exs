defmodule Alnasl.Repo.Migrations.LiveBoardControl do
  use Ecto.Migration

  # Live board control (board link revision 2): what `GET /link` last said
  # about the link's revision and its waiting commands, and every command
  # the box has carried out, by link and the pairing program's id, so a
  # command fetched twice is answered twice and carried out once.
  def change do
    alter table(:links) do
      add :revision, :integer
      add :commands, :integer, null: false, default: 0
    end

    create table(:remote_commands) do
      add :link_id, :integer, null: false
      add :remote_id, :integer, null: false
      add :kind, :string, null: false
      add :board_id, :integer
      add :status, :string, null: false
      add :error, :string
      add :detail, :string
      add :answered_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:remote_commands, [:link_id, :remote_id])
    create index(:remote_commands, [:inserted_at])
  end
end
