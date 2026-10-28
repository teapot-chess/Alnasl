defmodule Alnasl.MemoryDrafts.Draft do
  @moduledoc """
  A game as a board's memory has it, waiting for the arbiter
  (`Alnasl.MemoryDrafts`).

  `reason` is why it was not simply added: `"conflict"` (the memory went
  another way than the game), `"earlier_game"` (the pieces were set up
  again since, and an older game in the memory goes on from this one),
  `"ambiguous"` (two games in the memory fit) or `"unknown_start"` (the
  memory does not show where the game began). `plies` is JSON,
  `[%{"san", "flags", "clock"}]`, the whole game from `start_fen`; the first
  `from_ply` of them are the game's own. `status` is `"pending"`,
  `"accepted"` or `"dismissed"`.
  """
  use Ecto.Schema

  schema "memory_drafts" do
    field :game_id, :integer
    field :board_serial, :string
    field :reason, :string
    field :start_fen, :string
    field :from_ply, :integer, default: 0
    field :plies, :string, default: "[]"
    field :digest, :string
    field :status, :string, default: "pending"
    timestamps(type: :utc_datetime)
  end

  @reasons ~w(conflict earlier_game ambiguous unknown_start)
  def reasons, do: @reasons
end
