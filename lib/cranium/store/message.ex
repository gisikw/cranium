defmodule Cranium.Store.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "messages" do
    field :conversation_id, :string
    field :epoch_id, :binary_id
    field :role, :string
    field :content, :string
    field :origin, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :epoch_id, :role, :content, :origin])
    |> validate_required([:conversation_id, :role, :content])
  end
end
