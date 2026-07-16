defmodule Cranium.Store.RoomReadMarker do
  @moduledoc """
  Server-owned read position for a room. Single-tenant: one marker per
  room, no user dimension.

  `last_read_seq` is the room event seq the client has read through —
  the same currency as the sync cursor. `last_read_at` anchors the read
  position in time so `unread` can be derived against the permanent
  messages table even after room events age out.
  """

  use TypedEctoSchema
  import Ecto.Changeset

  @primary_key {:room_id, :string, autogenerate: false}

  typed_schema "room_read_markers" do
    field :last_read_seq, :integer
    field :last_read_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [:room_id, :last_read_seq, :last_read_at])
    |> validate_required([:room_id, :last_read_seq, :last_read_at])
  end
end
