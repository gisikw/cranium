defmodule Cranium.Context.PromptBuilder do
  @moduledoc """
  Assembles the system prompt from its constituent parts.

  The system prompt is a composite of:

  1. **Identity document** — the base personality/instructions (e.g., EXO.md)
  2. **Room handoff** — context from the previous session in this room,
     wrapped in `<room-handoff>` tags
  3. **Cross-room landscape** — summaries from other active rooms, wrapped
     in `<cross-room-context>` tags

  For fresh sessions, all three components are assembled. For resumed
  sessions, the system prompt from session creation is reused (stored
  in the session state).

  ## Canary Tags

  Handoff and landscape blocks include deterministic canary hashes for
  verification. These use FNV-1a on (label + date seed).
  """

  @spec process(map(), map()) :: {:ok, map()}
  def process(%{is_fresh: true} = message, context) do
    identity = Map.get(context, :identity, "")
    room_id = message.room_id

    handoff = load_handoff(room_id)
    landscape = build_landscape(room_id)

    system_prompt =
      [
        identity,
        format_handoff(handoff),
        format_landscape(landscape)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    {:ok, Map.put(message, :system_prompt, system_prompt)}
  end

  def process(message, _context) do
    # Resumed session — system prompt is reused from session state
    system_prompt =
      case message[:session_state] do
        {:ok, %{system_prompt: prompt}} -> prompt
        _ -> ""
      end

    {:ok, Map.put(message, :system_prompt, system_prompt)}
  end

  # --- Private ---

  defp load_handoff(room_id) do
    case Cranium.Store.get_latest_handoff(room_id) do
      {:ok, content} -> content
      :not_found -> nil
    end
  end

  defp build_landscape(exclude_room_id) do
    case Cranium.Store.get_all_summaries() do
      {:ok, summaries} ->
        summaries
        |> Enum.reject(&(&1.room_id == exclude_room_id))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      _ ->
        []
    end
  end

  defp format_handoff(nil), do: nil

  defp format_handoff(content) do
    canary = canary_hash("handoff")

    """
    <room-handoff>
    canary:handoff=#{canary}
    This is the handoff from your previous session in this room. Use it for context but don't reference it explicitly unless asked.

    #{content}
    </room-handoff>
    """
  end

  defp format_landscape([]), do: nil

  defp format_landscape(summaries) do
    canary = canary_hash("landscape")

    entries =
      summaries
      |> Enum.map(fn s ->
        age = format_age(s.updated_at)
        "- **#{s.room_id}** (last active #{age}): #{s.content}"
      end)
      |> Enum.join("\n")

    """
    <cross-room-context>
    canary:landscape=#{canary}
    Here's what's happening in your other rooms:

    #{entries}
    </cross-room-context>
    """
  end

  defp canary_hash(label) do
    date_seed = Date.utc_today() |> Date.to_string()
    :erlang.phash2({label, date_seed}) |> Integer.to_string(16) |> String.downcase()
  end

  defp format_age(nil), do: "unknown"

  defp format_age(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "about #{div(diff, 60)} minutes ago"
      diff < 86400 -> "about #{div(diff, 3600)} hours ago"
      true -> "about #{div(diff, 86400)} days ago"
    end
  end
end
