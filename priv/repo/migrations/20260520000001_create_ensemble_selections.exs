defmodule Cranium.Repo.Migrations.CreateEnsembleSelections do
  use Ecto.Migration

  def change do
    create table(:ensemble_selections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :epoch_id, references(:epochs, type: :binary_id, on_delete: :nilify_all)
      add :turn_count, :integer, null: false
      add :profile, :string, null: false
      add :model, :string
      add :backend, :string
      add :scores, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:ensemble_selections, [:epoch_id, :turn_count])
  end
end
