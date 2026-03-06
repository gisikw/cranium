defmodule Cranium.Store.Repo.Migrations.CreateStoreTables do
  use Ecto.Migration

  def change do
    create table(:epochs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :string, null: false
      add :status, :string, default: "active"
      add :system_prompt, :text
      add :turn_count, :integer, default: 0
      add :saturation, :float, default: 0.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:epochs, [:conversation_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :string, null: false
      add :role, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:messages, [:conversation_id, :inserted_at])

    create table(:handoffs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:handoffs, [:conversation_id, :inserted_at])

    create table(:summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:summaries, [:conversation_id])
  end
end
