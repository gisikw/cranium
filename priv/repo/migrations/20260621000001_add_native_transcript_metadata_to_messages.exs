defmodule Cranium.Store.Repo.Migrations.AddNativeTranscriptMetadataToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :parent_id, :binary_id
      add :provenance, :jsonb
    end

    create index(:messages, [:parent_id])
  end
end
