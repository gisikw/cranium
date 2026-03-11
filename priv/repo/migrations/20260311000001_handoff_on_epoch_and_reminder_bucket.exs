defmodule Cranium.Store.Repo.Migrations.HandoffOnEpochAndReminderBucket do
  use Ecto.Migration

  def change do
    alter table(:epochs) do
      add :handoff, :text
      add :last_reminder_bucket, :integer, default: 0
    end

    drop table(:handoffs)
  end
end
