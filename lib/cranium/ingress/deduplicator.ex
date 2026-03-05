defmodule Cranium.Ingress.Deduplicator do
  @moduledoc """
  Rejects duplicate events.

  Matrix delivers the same event multiple times (on reconnect, sync pagination,
  etc). This step maintains a bounded set of recently-seen event IDs and rejects
  duplicates.

  The seen-set is in-memory (process state in the Ingress GenServer). On restart,
  duplicates from the first sync batch may slip through — this is acceptable
  because the dedup window is short and the downstream pipeline is idempotent
  for display purposes.
  """

  @max_seen 10_000

  @doc """
  Check if this event has been seen before.

  Returns `{:ok, event}` if new, `{:error, :duplicate}` if seen.
  Uses an ETS table for O(1) lookups without blocking the Ingress GenServer.
  """
  @spec check(map(), map()) :: {:ok, map()} | {:error, :duplicate}
  def check(%{event_id: event_id} = event, _context) do
    table = ensure_table()

    case :ets.lookup(table, event_id) do
      [] ->
        :ets.insert(table, {event_id, true})
        maybe_evict(table)
        {:ok, event}

      _ ->
        {:error, :duplicate}
    end
  end

  defp ensure_table do
    case :ets.whereis(:cranium_seen_events) do
      :undefined ->
        :ets.new(:cranium_seen_events, [:set, :public, :named_table])

      ref ->
        ref
    end
  end

  defp maybe_evict(table) do
    if :ets.info(table, :size) > @max_seen do
      # Delete oldest half — crude but effective
      :ets.safe_fixtable(table, true)
      keys = :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])

      keys
      |> Enum.take(div(@max_seen, 2))
      |> Enum.each(&:ets.delete(table, &1))

      :ets.safe_fixtable(table, false)
    end
  end
end
