defmodule Cranium.Store.Repo.Migrations.AddUsageToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :usage, :jsonb
    end
  end
end
