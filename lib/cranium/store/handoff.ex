defmodule Cranium.Store.Handoff do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "handoffs" do
    field :conversation_id, :string
    field :content, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [:conversation_id, :content])
    |> validate_required([:conversation_id, :content])
  end
end
