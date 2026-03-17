defmodule Cranium.Store.Repo.Migrations.AddCcSessionIdToEpochs do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :cc_session_id, :string
    end
  end
end
