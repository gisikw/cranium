defmodule Cranium.Store.Repo.Migrations.AddToolUsesToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :tool_uses, :jsonb
    end
  end
end
