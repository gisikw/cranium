defmodule Cranium.Store.Repo.Migrations.AddBeliefStateToEpochs do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :last_belief_ids, {:array, :string}
    end
  end
end
