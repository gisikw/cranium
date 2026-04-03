defmodule Cranium.Store.Repo.Migrations.AddInjectionStateToEpochs do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :last_landscape_at, :utc_datetime
      add :interrupted_context, :text
    end
  end
end
