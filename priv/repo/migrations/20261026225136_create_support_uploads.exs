defmodule Alnasl.Repo.Migrations.CreateSupportUploads do
  use Ecto.Migration

  # Diagnostics a box sent for support (`Alnasl.Support`): the text, the
  # six-digit code it was answered with, what the box said about itself, and
  # a keyed hash of the sender's address for the rate limit - never the
  # address. Thirty days, then gone.
  def change do
    create table(:support_uploads) do
      add :code, :string, null: false
      add :content, :text, null: false
      add :size, :integer, null: false
      add :filename, :string
      add :box_id, :string
      add :version, :string
      add :mode, :string
      add :ip_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:support_uploads, [:code])
    create index(:support_uploads, [:ip_hash, :inserted_at])
    create index(:support_uploads, [:expires_at])
  end
end
