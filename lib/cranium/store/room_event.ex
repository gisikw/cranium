defmodule Cranium.Store.RoomEvent do
  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "room_events" do
    field :room_id, :string
    field :seq, :integer
    field :type, :string
    field :occurred_at, :utc_datetime_usec
    field :correlation_id, :string
    field :payload, :map, default: %{}
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:room_id, :seq, :type, :occurred_at, :correlation_id, :payload])
    |> validate_required([:room_id, :seq, :type, :occurred_at, :payload])
  end
end
