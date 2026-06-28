defmodule Cranium.Store.Repo.Migrations.CreateRoomEvents do
  use Ecto.Migration

  def change do
    create table(:room_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, :string, null: false
      add :seq, :bigint, null: false
      add :type, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :string
      add :payload, :map, null: false, default: %{}
    end

    # Primary query path: replay events after cursor for a room
    create unique_index(:room_events, [:room_id, :seq])

    # Age-out cleanup: find events older than horizon
    create index(:room_events, [:occurred_at])
  end
end
