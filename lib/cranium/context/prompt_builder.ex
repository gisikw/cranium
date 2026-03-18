defmodule Cranium.Context.PromptBuilder do
  @moduledoc """
  Assembles the system prompt.

  Uses the identity document passed in via `context.identity` (e.g., from
  the transport layer). Falls back to loading EXO.md from disk when no
  identity is provided.

  On fresh epochs, appends the handoff from the previous epoch as a
  `<room-handoff>` block. The handoff is identity — who you were last
  session — not per-turn context, so it lives in the system prompt.
  """

  require Logger

  @default_identity_path "/home/dev/Projects/hoard/prompts/EXO.md"

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    identity = resolve_identity(context)
    handoff = resolve_handoff(message)

    system_prompt =
      case handoff do
        nil -> identity
        content -> identity <> "\n\n<room-handoff>\n" <> content <> "\n</room-handoff>"
      end

    {:ok, Map.put(message, :system_prompt, system_prompt)}
  end

  # --- Private ---

  defp resolve_identity(%{identity: identity}) when is_binary(identity) and identity != "" do
    identity
  end

  defp resolve_identity(_context) do
    case File.read(@default_identity_path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        Logger.warning("Failed to load identity document",
          path: @default_identity_path,
          reason: reason
        )

        ""
    end
  end

  defp resolve_handoff(%{is_fresh: true, conversation_id: cid}) do
    case Cranium.Store.get_latest_handoff(cid) do
      {:ok, content} -> content
      :not_found -> resolve_handoff_from_disk(cid)
    end
  end

  defp resolve_handoff(_message), do: nil

  defp resolve_handoff_from_disk(conversation_id) do
    base = Application.get_env(:cranium, :paths)[:handoffs]

    if base do
      dir = Path.join(base, conversation_id)

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()
          |> List.last()
          |> case do
            nil -> nil
            file -> File.read!(Path.join(dir, file))
          end

        {:error, _} ->
          nil
      end
    end
  end
end
