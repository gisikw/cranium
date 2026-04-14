defmodule Cranium.Repo.Migrations.AddContinuationToEpochs do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :continuation, :text
    end
  end
end
