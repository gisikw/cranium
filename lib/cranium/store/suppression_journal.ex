defmodule Cranium.Store.SuppressionJournal do
  @moduledoc """
  Append-only journal for suppressed-thought spans.

  Content stripped from assistant messages by
  `Cranium.Inference.SuppressedThought` lands here and nowhere else. One
  JSONL line per span — `at` (ISO-8601 UTC), `room`, `epoch_id`, `content`
  (verbatim) — so the journal stays trivially greppable.

  Writes are best-effort: a failed append logs a warning and never blocks
  the pass. Privacy beats trace — the caller strips regardless of whether
  journaling succeeded.

  The path comes from `config :cranium, :paths, suppression_journal: ...`;
  nil disables journaling.
  """

  require Logger

  @spec append(String.t(), term(), [String.t()]) :: :ok
  def append(_room, _epoch_id, []), do: :ok

  def append(room, epoch_id, spans) when is_list(spans) do
    case journal_path() do
      nil -> :ok
      path -> write(path, room, epoch_id, spans)
    end
  end

  defp write(path, room, epoch_id, spans) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    lines =
      Enum.map(spans, fn content ->
        Jason.encode!(%{at: at, room: room, epoch_id: epoch_id, content: content}) <> "\n"
      end)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, IO.iodata_to_binary(lines), [:append]) do
      :ok
    else
      error ->
        Logger.warning("SuppressionJournal: append failed: #{inspect(error)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("SuppressionJournal: append failed: #{inspect(error)}")
      :ok
  end

  defp journal_path do
    case Application.get_env(:cranium, :paths) do
      paths when is_list(paths) -> Keyword.get(paths, :suppression_journal)
      _ -> nil
    end
  end
end
