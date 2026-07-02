defmodule Cranium.RoomSync.Timestamp do
  @moduledoc """
  Canonical timestamp serialization for the room sync protocol.

  Timestamp sources vary in precision (microsecond Ecto fields vs
  second-truncated epoch fields), which previously leaked two ISO 8601
  flavors onto the wire. Every room-sync boundary formats timestamps
  through here: ISO 8601 UTC, second precision.
  """

  @spec iso8601(DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t() | nil
  def iso8601(nil), do: nil

  def iso8601(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def iso8601(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> iso8601()
  end

  def iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> iso8601(dt)
      _ -> value
    end
  end
end
