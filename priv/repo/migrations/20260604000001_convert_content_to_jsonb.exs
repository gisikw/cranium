defmodule Cranium.Store.Repo.Migrations.ConvertContentToJsonb do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE messages
    ALTER COLUMN content TYPE jsonb
    USING jsonb_build_array(jsonb_build_object('type', 'text', 'text', content))
    """

    execute """
    ALTER TABLE messages ALTER COLUMN content SET DEFAULT '[]'::jsonb
    """
  end

  def down do
    execute """
    ALTER TABLE messages
    ALTER COLUMN content TYPE text
    USING (content->0->>'text')
    """

    execute """
    ALTER TABLE messages ALTER COLUMN content SET DEFAULT ''
    """
  end
end
