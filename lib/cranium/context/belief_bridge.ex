defmodule Cranium.Context.BeliefBridge do
  @moduledoc """
  Reads the published gee bridge artifact and extracts the belief block.

  The artifact is published atomically (write temp + rename) by a periodic
  systemd unit running `gee eval --bridge` — the single writer to the
  belief ledger, since `gee eval` appends mechanical status transitions.
  Cranium only ever reads the published file and never invokes `gee`
  itself. See docs/gee-belief-injection.md.

  Artifact shape (gee format.go):

      <gee mode="task" surfaced="1" active="5" beliefs="14" pinned="2">
      ...awareness items...
      <beliefs pinned="2" surfaced="3">
      [B-001] statement (0.95)
      ---
      [B-042] statement (0.50, contested)
      </beliefs>
      </gee>

  Pinned beliefs appear above the `---` separator, the surfaced band below,
  sorted by activation descending. The separator is omitted when either
  section is empty, so section membership is derived from the element's
  pinned/surfaced counts, not the separator.
  """

  @stale_after_seconds 2 * 60 * 60

  @type entry :: %{id: String.t(), line: String.t()}
  @type snapshot :: %{pinned: [entry()], surfaced: [entry()]}

  @doc """
  Read and parse the bridge artifact at `path`.

  Returns `{:ok, snapshot}` or an error tuple when the artifact is missing,
  stale (mtime older than #{div(@stale_after_seconds, 3600)}h), unreadable,
  or carries no beliefs. Never raises — a broken bridge must not block a
  turn.
  """
  @spec read_snapshot(String.t(), DateTime.t()) ::
          {:ok, snapshot()} | {:error, :missing | :stale | :empty | :unreadable}
  def read_snapshot(path, now \\ DateTime.utc_now()) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         :fresh <- freshness(mtime, now),
         {:ok, content} <- File.read(path) do
      case parse(content) do
        %{pinned: [], surfaced: []} -> {:error, :empty}
        snapshot -> {:ok, snapshot}
      end
    else
      {:error, :enoent} -> {:error, :missing}
      :stale -> {:error, :stale}
      {:error, _posix} -> {:error, :unreadable}
    end
  end

  defp freshness(mtime_posix, now) do
    if DateTime.to_unix(now) - mtime_posix > @stale_after_seconds,
      do: :stale,
      else: :fresh
  end

  @doc """
  Extract belief entries from bridge output. Pure.

  Unparseable content degrades to an empty snapshot.
  """
  @spec parse(String.t()) :: snapshot()
  def parse(content) when is_binary(content) do
    with [attrs, body] <-
           Regex.run(~r|<beliefs([^>]*)>\n(.*?)</beliefs>|s, content, capture: :all_but_first),
         pinned_count when is_integer(pinned_count) <- int_attr(attrs, "pinned") do
      entries =
        body
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == "---"))
        |> Enum.flat_map(&entry_from_line/1)

      {pinned, surfaced} = Enum.split(entries, pinned_count)
      %{pinned: pinned, surfaced: surfaced}
    else
      _ -> %{pinned: [], surfaced: []}
    end
  end

  defp int_attr(attrs, name) do
    case Regex.run(~r/#{name}="(\d+)"/, attrs, capture: :all_but_first) do
      [n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp entry_from_line(line) do
    case Regex.run(~r/^\[([^\]]+)\]/, line, capture: :all_but_first) do
      [id] -> [%{id: id, line: line}]
      nil -> []
    end
  end
end
