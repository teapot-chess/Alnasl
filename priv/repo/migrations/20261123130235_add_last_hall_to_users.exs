defmodule Alnasl.Repo.Migrations.AddLastHallToUsers do
  use Ecto.Migration

  # The hall an account last chose with the hall picker, so a new session
  # (the remember cookie, a sign-in after a sign-out) opens there instead of
  # in whichever hall sorts first. A plain number, not a reference: a hall
  # that is gone, or one the account lost, is simply not picked
  # (`Alnasl.Accounts.scope/2` only picks among the halls it may see).
  def change do
    alter table(:users) do
      add :last_hall_id, :integer
    end
  end
end
