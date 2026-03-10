defmodule Cranium.Store.Repo.Migrations.EpochAccumulation do
  use Ecto.Migration

  def change do
    # Epochs accumulate — drop unique constraint so multiple epochs
    # can exist per conversation (latest one is the active epoch).
    drop unique_index(:epochs, [:conversation_id])
    create index(:epochs, [:conversation_id, :inserted_at])

    # Messages belong to an epoch, not just a conversation.
    alter table(:messages) do
      add :epoch_id, references(:epochs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:messages, [:epoch_id])
  end
end
