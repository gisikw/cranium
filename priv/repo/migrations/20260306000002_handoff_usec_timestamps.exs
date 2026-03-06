defmodule Cranium.Store.Repo.Migrations.HandoffUsecTimestamps do
  use Ecto.Migration

  def change do
    alter table(:handoffs) do
      modify :inserted_at, :utc_datetime_usec, from: :utc_datetime
    end
  end
end
