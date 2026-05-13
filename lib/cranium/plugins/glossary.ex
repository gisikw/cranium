defmodule Cranium.Plugins.Glossary do
  @moduledoc """
  First-mention glossary injection plugin.

  Loads glossary entries (markdown files with YAML frontmatter) from a
  configured directory. On each turn, scans the user's message for mentions
  of known terms. Injects context snippets only on first mention per session,
  avoiding context bloat from repeated injections.

  ## Configuration

  In profiles.yaml:

      plugins:
        - module: Cranium.Plugins.Glossary
          config:
            path: /home/dev/Projects/hoard/glossary
            priority: 15

  - `path` — directory containing glossary .md files (required)
  - `priority` — injection priority (default: 15, between time-gap and landscape)

  ## Glossary entry format

  Each .md file has YAML frontmatter with `aliases` and `summary`:

      ---
      aliases: [jdoe]
      summary: "Jane Doe is a Sr. Engineer on the platform team"
      ---

      Optional extended body content.

  The filename (minus .md) is the canonical term. Aliases are additional
  match patterns. Matching is case-insensitive with word boundaries.

  ## Re-injection

  A term is injected once per session. If the glossary file's mtime changes
  mid-session, the term becomes eligible for re-injection.
  """

  @behaviour Cranium.Plugin

  require Logger

  @default_priority 15

  @impl true
  def init(metadata) do
    config = metadata.plugin_config || %{}
    path = config["path"]

    if is_nil(path) or not File.dir?(path) do
      Logger.debug("Glossary: no valid path configured, ignoring session",
        conversation_id: metadata.conversation_id
      )

      :ignore
    else
      entries = load_glossary(path)

      Logger.info("Glossary: loaded #{map_size(entries)} entries from #{path}",
        conversation_id: metadata.conversation_id
      )

      state = %{
        entries: entries,
        path: path,
        priority: config["priority"] || @default_priority,
        seen: %{}
      }

      {:ok, [:before_context_build], state}
    end
  end

  @impl true
  def before_context_build(turn_context, state) do
    text = turn_context.message_text
    matches = scan(text, state.entries, state.seen)

    case matches do
      [] ->
        {:ok, :skip, state}

      _ ->
        # Update seen-state
        now = DateTime.utc_now()

        seen =
          Enum.reduce(matches, state.seen, fn entry, acc ->
            Map.put(acc, entry.term, %{at: now, mtime: entry.mtime})
          end)

        # Build injection content
        content = format_injection(matches)
        injection = %{priority: state.priority, content: content}

        {:ok, [injection], %{state | seen: seen}}
    end
  end

  # --- Glossary loading ---

  defp load_glossary(path) do
    path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file, acc ->
      case parse_entry(file) do
        {:ok, entry} ->
          # Index by canonical term and each alias
          acc = Map.put(acc, entry.term, entry)

          Enum.reduce(entry.aliases, acc, fn alias_name, inner_acc ->
            Map.put(inner_acc, String.downcase(alias_name), entry)
          end)

        :error ->
          acc
      end
    end)
  end

  defp parse_entry(file) do
    term = file |> Path.basename(".md")

    with {:ok, content} <- File.read(file),
         {:ok, %{frontmatter: fm}} <- parse_frontmatter(content),
         summary when is_binary(summary) <- fm["summary"] do
      mtime =
        case File.stat(file) do
          {:ok, %{mtime: mtime}} -> mtime
          _ -> nil
        end

      {:ok,
       %{
         term: term,
         aliases: fm["aliases"] || [],
         summary: summary,
         body: extract_body(content),
         mtime: mtime,
         pattern: build_pattern(term, fm["aliases"] || [])
       }}
    else
      _ -> :error
    end
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml_str] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, map} -> {:ok, %{frontmatter: map}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp extract_body(content) do
    case Regex.run(~r/\A---\n.*?\n---\n*(.*)/s, content) do
      [_, body] ->
        trimmed = String.trim(body)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp build_pattern(term, aliases) do
    terms = [term | aliases]

    patterns =
      terms
      |> Enum.map(fn t ->
        escaped = Regex.escape(t)
        # Allow hyphens to match spaces and vice versa
        # Regex.escape turns "-" into "\\-", so replace that
        escaped = String.replace(escaped, "\\-", "[-\\s]")
        "\\b#{escaped}\\b"
      end)
      |> Enum.join("|")

    Regex.compile!(patterns, [:caseless])
  end

  # --- Scanning ---

  defp scan(text, entries, seen) do
    entries
    |> Map.values()
    |> Enum.uniq_by(& &1.term)
    |> Enum.filter(fn entry ->
      Regex.match?(entry.pattern, text) and not already_seen?(entry, seen)
    end)
  end

  defp already_seen?(entry, seen) do
    case Map.get(seen, entry.term) do
      nil -> false
      %{mtime: seen_mtime} -> seen_mtime == entry.mtime
    end
  end

  # --- Formatting ---

  defp format_injection(matches) do
    entries =
      matches
      |> Enum.sort_by(& &1.term)
      |> Enum.map_join("\n", fn entry ->
        base = "- **#{entry.term}**: #{entry.summary}"

        if entry.body do
          "#{base}\n  #{String.replace(entry.body, "\n", "\n  ")}"
        else
          base
        end
      end)

    "<glossary>\n#{entries}\n</glossary>"
  end
end
