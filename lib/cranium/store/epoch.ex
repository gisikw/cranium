defmodule Cranium.Store.Epoch do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "epochs" do
    field :conversation_id, :string
    field :status, :string, default: "active"
    field :system_prompt, :string
    field :turn_count, :integer, default: 0
    field :saturation, :float, default: 0.0
    field :handoff, :string
    field :last_reminder_bucket, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(epoch, attrs) do
    epoch
    |> cast(attrs, [
      :conversation_id,
      :status,
      :system_prompt,
      :turn_count,
      :saturation,
      :handoff,
      :last_reminder_bucket
    ])
    |> validate_required([:conversation_id])
  end
end
