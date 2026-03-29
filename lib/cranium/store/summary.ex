defmodule Cranium.Store.Summary do
  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "summaries" do
    field :conversation_id, :string
    field :content, :string

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [:conversation_id, :content])
    |> validate_required([:conversation_id, :content])
    |> unique_constraint(:conversation_id)
  end
end
