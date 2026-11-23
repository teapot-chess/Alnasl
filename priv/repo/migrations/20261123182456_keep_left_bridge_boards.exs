defmodule Alnasl.Repo.Migrations.KeepLeftBridgeBoards do
  use Ecto.Migration

  # Where a removed bridge's boards stood (JSON: table, tournament, round,
  # board, flipped, name per port), so that the same bridge joining the same
  # hall again soon after picks its tables up where it left them
  # (`Alnasl.Bridges.forget/1`, `Alnasl.Bridges.board_row/2`).
  def change do
    alter table(:bridges) do
      add :left_boards, :text
    end
  end
end
