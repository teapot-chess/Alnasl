defmodule Alnasl.Support.Upload do
  @moduledoc """
  One diagnostics file a box sent for support (`Alnasl.Support`). Every
  field but the code and the expiry came from an unauthenticated stranger
  and is shown as text, never as markup.
  """

  use Ecto.Schema

  schema "support_uploads" do
    field :code, :string
    field :content, :string
    field :size, :integer
    field :filename, :string
    field :box_id, :string
    field :version, :string
    field :mode, :string
    field :ip_hash, :string, redact: true
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
