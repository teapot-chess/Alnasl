defmodule Alnasl.Repo.Migrations.UiMode do
  use Ecto.Migration

  # Simple mode (`AlnaslWeb.Mode`, docs/simple-mode.md): a new installation
  # starts with the basics only; one that was already in use keeps every
  # page it had, so nobody comes in on the morning after an update to find
  # half the menu gone.
  #
  # "In use" is anything a person made: an account, a board, a game, a
  # setting. A fresh database has none of them when this runs (the earlier
  # migrations only write settings that an older version had kept), so the
  # absence of all four is a new installation and it is left to the default.
  #
  # `users.ui_mode` is an account's own choice, `nil` until it makes one:
  # then the installation's word counts.
  def up do
    alter table(:users) do
      add :ui_mode, :string
    end

    flush()

    %{rows: [[used]]} =
      repo().query!("""
      SELECT (SELECT COUNT(*) FROM users) + (SELECT COUNT(*) FROM boards)
           + (SELECT COUNT(*) FROM games) + (SELECT COUNT(*) FROM settings)
      """)

    if used > 0 do
      repo().query!(
        "INSERT INTO settings (key, value) VALUES ('ui_mode', ?) ON CONFLICT(key) DO NOTHING",
        [Jason.encode!("full")]
      )
    end
  end

  def down do
    repo().query!("DELETE FROM settings WHERE key = 'ui_mode'")

    alter table(:users) do
      remove :ui_mode
    end
  end
end
