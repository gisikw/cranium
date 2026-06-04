defmodule Cranium.Store.Message do
  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "messages" do
    field :conversation_id, :string
    field :epoch_id, :binary_id
    field :role, :string
    field :content, {:array, :map}
    field :origin, :string
    field :tool_uses, {:array, :map}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :epoch_id, :role, :content, :origin, :tool_uses])
    |> validate_required([:conversation_id, :role, :content])
  end
end
