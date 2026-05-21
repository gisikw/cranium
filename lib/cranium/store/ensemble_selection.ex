defmodule Cranium.Store.EnsembleSelection do
  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "ensemble_selections" do
    field :epoch_id, :binary_id
    field :turn_count, :integer
    field :profile, :string
    field :model, :string
    field :backend, :string
    field :scores, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(selection, attrs) do
    selection
    |> cast(attrs, [:epoch_id, :turn_count, :profile, :model, :backend, :scores])
    |> validate_required([:epoch_id, :turn_count, :profile])
  end
end
