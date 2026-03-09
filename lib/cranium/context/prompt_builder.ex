defmodule Cranium.Context.PromptBuilder do
  @moduledoc """
  Assembles the system prompt.

  Uses the identity document passed in via `context.identity` (e.g., from
  the transport layer). Falls back to loading EXO.md from disk when no
  identity is provided. Kept as a dedicated module for future dynamic
  prompt assembly (handoffs, cross-conversation landscape, etc.).
  """

  require Logger

  @default_identity_path "/home/dev/Projects/exocortex/notes/EXO.md"

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    system_prompt = resolve_identity(context)
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
end
