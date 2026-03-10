defmodule Cranium.Effects do
  @moduledoc """
  Async side-effects stage.

  Handles work triggered by pipeline events that is not on the critical
  path. Effects run as supervised Tasks under `Cranium.Effects.Supervisor`
  — if a handoff generation fails, it doesn't affect the active epoch.

  Decomposes into two steps:

  - `HandoffWriter` — on `!clear`, generates a handoff document via a
    separate LLM call that summarizes the epoch. The handoff is stored
    and injected into the next epoch's system prompt.
  - `ConversationSummarizer` — every N turns, generates a cross-conversation
    summary via a separate LLM call. Summaries are stored and used for
    cross-conversation awareness (the "landscape").

  ## Timing

  Effects are fire-and-forget from the Epoch's perspective. The Epoch
  doesn't wait for handoff generation to complete before clearing. Summary
  generation happens in the background after the Nth turn completes.

  Both effects use the LLM backend but with separate, minimal prompts —
  they don't inherit the full epoch context.
  """

  require Logger

  @doc """
  Generate a handoff document for a conversation.

  Spawns a Task under the Effects supervisor. Returns immediately.
  """
  @spec generate_handoff(String.t(), String.t()) :: :ok
  def generate_handoff(conversation_id, epoch_id) do
    Task.Supervisor.start_child(
      Cranium.Effects.Supervisor,
      fn -> Cranium.Effects.HandoffWriter.generate(conversation_id, epoch_id) end,
      restart: :temporary
    )

    :ok
  end

  @doc """
  Generate a cross-conversation summary.

  Spawns a Task under the Effects supervisor. Returns immediately.
  """
  @spec generate_summary(String.t()) :: :ok
  def generate_summary(conversation_id) do
    Logger.info("Generating summary", conversation_id: conversation_id, stage: :effects)

    Task.Supervisor.start_child(
      Cranium.Effects.Supervisor,
      fn -> Cranium.Effects.ConversationSummarizer.generate(conversation_id) end,
      restart: :temporary
    )

    :ok
  end
end
