defmodule Cranium.Context.BeliefManifest do
  @moduledoc """
  Append-only log of belief injections, keyed by room/epoch/turn.

  One JSON object per line recording which belief IDs entered context and
  what they cost. This is the raw material for reference-rate and holdout
  analysis — the nightly accretion pass (Dispatch C) consumes it to tell
  evidence that arose with a belief in context apart from evidence that
  arose independently.

  Writes are best-effort: a failed append logs a warning and never blocks
  the turn.
  """

  require Logger

  @doc """
  Append one injection record. `entry` carries `:room`, `:epoch_id`,
  `:turn`, `:kind`, `:ids`, `:tokens`, and `:dropped`.
  """
  @spec append(String.t() | nil, map()) :: :ok
  def append(nil, _entry), do: :ok

  def append(path, entry) do
    record =
      entry
      |> Map.put(:at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Map.put(:source, "gee-beliefs")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(record),
         :ok <- File.write(path, json <> "\n", [:append]) do
      :ok
    else
      error ->
        Logger.warning("BeliefManifest: append failed: #{inspect(error)}")
        :ok
    end
  end
end
