defmodule Cranium.Store.Epoch do
  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "epochs" do
    field :conversation_id, :string
    field :status, :string, default: "active"
    field :system_prompt, :string
    field :turn_count, :integer, default: 0
    field :saturation, :float, default: 0.0
    field :handoff, :string
    field :last_reminder_bucket, :integer, default: 0
    field :cc_session_id, :string
    field :last_landscape_at, :utc_datetime
    field :interrupted_context, :string

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(epoch, attrs) do
    epoch
    |> cast(attrs, [
      :conversation_id,
      :status,
      :system_prompt,
      :turn_count,
      :saturation,
      :handoff,
      :last_reminder_bucket,
      :cc_session_id,
      :last_landscape_at,
      :interrupted_context
    ])
    |> validate_required([:conversation_id])
  end
end
