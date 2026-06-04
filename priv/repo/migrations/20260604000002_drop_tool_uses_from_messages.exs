defmodule Cranium.Store.Repo.Migrations.DropToolUsesFromMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      remove :tool_uses, :jsonb
    end
  end
end
