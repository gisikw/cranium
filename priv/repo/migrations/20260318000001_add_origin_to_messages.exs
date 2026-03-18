defmodule Cranium.Store.Repo.Migrations.AddOriginToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :origin, :string
    end
  end
end
