defmodule Cranium.Store.Repo.Migrations.AddProfileToEpochs do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :profile, :string
    end
  end
end
