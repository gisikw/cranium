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
  @default_window_radius 3

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
      {entries, file_mtimes} = load_glossary(path)

      Logger.info("Glossary: loaded #{map_size(entries)} entries from #{path}",
        conversation_id: metadata.conversation_id
      )

      update_model = config["update_model"]

      hooks =
        if update_model,
          do: [:before_context_build, :on_epoch_end],
          else: [:before_context_build]

      state = %{
        entries: entries,
        path: path,
        priority: config["priority"] || @default_priority,
        seen: %{},
        mentions: %{},
        file_mtimes: file_mtimes,
        room_name: metadata.room_name,
        update_model: update_model,
        ollama_endpoint: config["ollama_endpoint"] || Cranium.Config.ollama_url(),
        window_radius: config["window_radius"] || @default_window_radius,
        req_opts: config["req_opts"] || [],
        async: Map.get(config, "async", true)
      }

      {:ok, hooks, state}
    end
  end

  @impl true
  def before_context_build(turn_context, state) do
    state = maybe_reload(state)
    text = turn_context.message_text
    turn = turn_context.turn_count

    # Find all matching terms (regardless of seen status)
    all_matches = scan_all(text, state.entries)

    # Track every mention for epoch-end windowing
    mentions =
      Enum.reduce(all_matches, state.mentions, fn entry, acc ->
        Map.update(acc, entry.term, [turn], &[turn | &1])
      end)

    state = %{state | mentions: mentions}

    # Filter to only injectable (first-mention or file-changed)
    injectable = Enum.filter(all_matches, &(not already_seen?(&1, state.seen)))

    case injectable do
      [] ->
        {:ok, :skip, state}

      _ ->
        now = DateTime.utc_now()

        seen =
          Enum.reduce(injectable, state.seen, fn entry, acc ->
            Map.put(acc, entry.term, %{at: now, mtime: entry.mtime})
          end)

        content = format_injection(injectable)
        injection = %{priority: state.priority, content: content}

        {:ok, [injection], %{state | seen: seen}}
    end
  end

  # --- Reload on file change ---

  defp maybe_reload(state) do
    current = current_file_mtimes(state.path)

    if current == state.file_mtimes do
      state
    else
      {entries, file_mtimes} = load_glossary(state.path)

      Logger.info("Glossary: reloaded #{map_size(entries)} entries (files changed)")

      %{state | entries: entries, file_mtimes: file_mtimes}
    end
  end

  defp current_file_mtimes(path) do
    path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Map.new(fn file ->
      mtime =
        case File.stat(file) do
          {:ok, %{mtime: m}} -> m
          _ -> nil
        end

      {file, mtime}
    end)
  end

  # --- Glossary loading ---

  defp load_glossary(path) do
    files =
      path
      |> Path.join("*.md")
      |> Path.wildcard()

    file_mtimes =
      Map.new(files, fn file ->
        mtime =
          case File.stat(file) do
            {:ok, %{mtime: m}} -> m
            _ -> nil
          end

        {file, mtime}
      end)

    entries =
      Enum.reduce(files, %{}, fn file, acc ->
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

    {entries, file_mtimes}
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

  defp scan_all(text, entries) do
    entries
    |> Map.values()
    |> Enum.uniq_by(& &1.term)
    |> Enum.filter(fn entry ->
      Regex.match?(entry.pattern, text)
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

  # --- Auto-update (epoch end) ---

  @impl true
  def on_epoch_end(epoch_end_context, state) do
    if state.update_model && map_size(state.mentions) > 0 do
      if state.async do
        # Fire-and-forget: don't block the GenServer (invariant: AutoUpdateNonBlocking)
        Task.start(fn -> do_auto_update(epoch_end_context, state) end)
      else
        do_auto_update(epoch_end_context, state)
      end
    end

    :ok
  end

  defp do_auto_update(epoch_end_context, state) do
    messages = epoch_end_context.messages

    for {term, turn_indices} <- state.mentions do
      entry = Map.get(state.entries, term)

      if entry do
        excerpts = build_window(turn_indices, messages, state.window_radius)

        case evaluate_update(term, entry, excerpts, state) do
          {:update, proposed_summary, rationale} ->
            case apply_update(term, proposed_summary, rationale, state) do
              :ok ->
                Logger.info("Glossary: updated \"#{term}\"",
                  rationale: rationale,
                  room: state.room_name
                )

              {:error, reason} ->
                Logger.warning("Glossary: failed to write update for \"#{term}\"",
                  error: inspect(reason)
                )
            end

          :no_update ->
            Logger.debug("Glossary: no update needed for \"#{term}\"")

          {:error, reason} ->
            Logger.warning("Glossary: evaluation failed for \"#{term}\"",
              error: inspect(reason)
            )
        end
      end
    end
  end

  defp build_window(turn_indices, messages, radius) do
    len = length(messages)

    # Turn indices are stored in reverse (newest first), sort them
    ranges =
      turn_indices
      |> Enum.sort()
      |> Enum.map(fn idx ->
        {max(0, idx - radius), min(len - 1, idx + radius)}
      end)

    # Merge overlapping ranges
    merged = merge_ranges(ranges)

    # Extract and format messages
    merged
    |> Enum.flat_map(fn {lo, hi} ->
      Enum.slice(messages, lo..hi)
    end)
    |> Enum.map_join("\n", fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = msg[:content] || msg["content"] || ""
      "#{role}: #{content}"
    end)
  end

  defp merge_ranges([]), do: []
  defp merge_ranges([single]), do: [single]

  defp merge_ranges([{a_lo, a_hi}, {b_lo, b_hi} | rest]) when b_lo <= a_hi + 1 do
    merge_ranges([{a_lo, max(a_hi, b_hi)} | rest])
  end

  defp merge_ranges([head | rest]) do
    [head | merge_ranges(rest)]
  end

  defp evaluate_update(term, entry, excerpts, state) do
    prompt = """
    You are reviewing a glossary entry for potential updates.

    Current entry for "#{term}":
    #{entry.summary}

    Conversation excerpts where "#{term}" was discussed:
    #{excerpts}

    The user's statements are ground truth. If the user corrects, \
    updates, or provides new information about this term, propose \
    an updated summary. If the conversation merely mentions the \
    term without adding or correcting information, respond with \
    no update.

    Respond as JSON:
    {"update": true, "summary": "...", "rationale": "..."} or
    {"update": false}
    """

    body = %{
      model: state.update_model,
      messages: [%{role: "user", content: prompt}],
      stream: false,
      format: "json"
    }

    req_opts =
      [json: body, receive_timeout: 60_000] ++ state.req_opts

    case Req.post("#{state.ollama_endpoint}/api/chat", req_opts) do
      {:ok, %{status: 200, body: resp}} ->
        parse_update_response(resp)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:raised, Exception.message(e)}}
  end

  defp parse_update_response(resp) when is_binary(resp) do
    case Jason.decode(resp) do
      {:ok, parsed} -> parse_update_response(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_update_response(%{"message" => %{"content" => content}}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> parse_update_payload(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_update_response(%{} = payload) do
    parse_update_payload(payload)
  end

  defp parse_update_response(_), do: {:error, :unexpected_response}

  defp parse_update_payload(%{"update" => true, "summary" => summary, "rationale" => rationale})
       when is_binary(summary) and is_binary(rationale) do
    {:update, summary, rationale}
  end

  defp parse_update_payload(%{"update" => false}), do: :no_update
  defp parse_update_payload(_), do: {:error, :malformed_payload}

  defp apply_update(term, proposed_summary, rationale, state) do
    file = Path.join(state.path, "#{term}.md")

    case File.read(file) do
      {:ok, content} ->
        updated = replace_summary(content, proposed_summary)
        date = Date.utc_today() |> Date.to_iso8601()
        changelog = "\n<!-- updated #{date} from session #{state.room_name}: #{rationale} -->\n"
        final = updated <> changelog

        # Atomic write: temp file then rename
        tmp = file <> ".tmp"

        with :ok <- File.write(tmp, final),
             :ok <- File.rename(tmp, file) do
          :ok
        else
          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_summary(content, new_summary) do
    # Replace the summary line in YAML frontmatter, preserving quoting style
    Regex.replace(
      ~r/^(summary:\s*).*$/m,
      content,
      "\\1\"#{String.replace(new_summary, "\"", "\\\"")}\"",
      global: false
    )
  end
end
