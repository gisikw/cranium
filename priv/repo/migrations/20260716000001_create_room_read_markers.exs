defmodule Cranium.Store.Repo.Migrations.CreateRoomReadMarkers do
  use Ecto.Migration

  def change do
    create table(:room_read_markers, primary_key: false) do
      add :room_id, :string, primary_key: true
      add :last_read_seq, :bigint, null: false
      add :last_read_at, :utc_datetime_usec, null: false
    end
  end
end
