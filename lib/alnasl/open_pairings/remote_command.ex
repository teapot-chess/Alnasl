defmodule Alnasl.OpenPairings.RemoteCommand do
  @moduledoc """
  A command of the arbiter, carried out on this box, as the box remembers
  it: the link it came through, the pairing program's id for it, and how
  it went (`done`, or `failed` with an error code and a sentence).

  Written before the answer is sent. The pairing program hands a command
  out again until it has an answer, so a box that fell over between the
  two answers again with what is written here, and does not carry the
  command out a second time (`Alnasl.OpenPairings.Commands`).
  """
  use Ecto.Schema

  schema "remote_commands" do
    field :link_id, :integer
    field :remote_id, :integer
    field :kind, :string
    field :board_id, :integer
    field :status, :string
    field :error, :string
    field :detail, :string
    field :answered_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
