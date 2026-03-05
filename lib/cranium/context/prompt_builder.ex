defmodule Cranium.Context.PromptBuilder do
  @moduledoc """
  Assembles the system prompt from its constituent parts.

  The system prompt is a composite of:

  1. **Identity document** — the base personality/instructions (e.g., EXO.md)
  2. **Conversation handoff** — context from the previous epoch in this
     conversation, wrapped in `<conversation-handoff>` tags
  3. **Cross-conversation landscape** — summaries from other active
     conversations, wrapped in `<cross-conversation-context>` tags

  For fresh epochs, all three components are assembled. For resumed
  epochs, the system prompt from epoch creation is reused (stored
  in the epoch state).

  ## Canary Tags

  Handoff and landscape blocks include deterministic canary hashes for
  verification. These use FNV-1a on (label + date seed).
  """

  @spec process(map(), map()) :: {:ok, map()}
  def process(%{is_fresh: true} = message, context) do
    identity = Map.get(context, :identity, "")
    conversation_id = message.conversation_id

    handoff = load_handoff(conversation_id)
    landscape = build_landscape(conversation_id)

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
    # Resumed epoch — system prompt is reused from epoch state
    system_prompt =
      case message[:epoch_state] do
        {:ok, %{system_prompt: prompt}} -> prompt
        _ -> ""
      end

    {:ok, Map.put(message, :system_prompt, system_prompt)}
  end

  # --- Private ---

  defp load_handoff(conversation_id) do
    case Cranium.Store.get_latest_handoff(conversation_id) do
      {:ok, content} -> content
      :not_found -> nil
    end
  end

  defp build_landscape(exclude_conversation_id) do
    case Cranium.Store.get_all_summaries() do
      {:ok, summaries} ->
        summaries
        |> Enum.reject(&(&1.conversation_id == exclude_conversation_id))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      _ ->
        []
    end
  end

  defp format_handoff(nil), do: nil

  defp format_handoff(content) do
    canary = canary_hash("handoff")

    """
    <conversation-handoff>
    canary:handoff=#{canary}
    This is the handoff from your previous epoch in this conversation. Use it for context but don't reference it explicitly unless asked.

    #{content}
    </conversation-handoff>
    """
  end

  defp format_landscape([]), do: nil

  defp format_landscape(summaries) do
    canary = canary_hash("landscape")

    entries =
      summaries
      |> Enum.map(fn s ->
        age = format_age(s.updated_at)
        "- **#{s.conversation_id}** (last active #{age}): #{s.content}"
      end)
      |> Enum.join("\n")

    """
    <cross-conversation-context>
    canary:landscape=#{canary}
    Here's what's happening in your other conversations:

    #{entries}
    </cross-conversation-context>
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
