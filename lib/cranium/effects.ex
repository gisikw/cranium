defmodule Cranium.Effects do
  @moduledoc """
  Async side-effects stage.

  Handles work triggered by pipeline events that is not on the critical
  path. Effects run as supervised Tasks under `Cranium.Effects.Supervisor`
  — if a handoff generation fails, it doesn't affect the active session.

  Decomposes into two steps:

  - `HandoffWriter` — on `!clear`, generates a handoff document via a
    separate LLM call that summarizes the session. The handoff is stored
    and injected into the next session's system prompt.
  - `RoomSummarizer` — every N turns, generates a cross-room summary via
    a separate LLM call. Summaries are stored and used for cross-room
    awareness (the "landscape").

  ## Timing

  Effects are fire-and-forget from the Session's perspective. The Session
  doesn't wait for handoff generation to complete before clearing. Summary
  generation happens in the background after the Nth turn completes.

  Both effects use the LLM backend but with separate, minimal prompts —
  they don't inherit the full session context.
  """

  require Logger

  @doc """
  Generate a handoff document for a room.

  Spawns a Task under the Effects supervisor. Returns immediately.
  """
  @spec generate_handoff(String.t()) :: :ok
  def generate_handoff(room_id) do
    Logger.info("Generating handoff", room_id: room_id, stage: :effects)

    Task.Supervisor.start_child(
      Cranium.Effects.Supervisor,
      fn -> Cranium.Effects.HandoffWriter.generate(room_id) end,
      restart: :temporary
    )

    :ok
  end

  @doc """
  Generate a cross-room summary for a room.

  Spawns a Task under the Effects supervisor. Returns immediately.
  """
  @spec generate_summary(String.t()) :: :ok
  def generate_summary(room_id) do
    Logger.info("Generating summary", room_id: room_id, stage: :effects)

    Task.Supervisor.start_child(
      Cranium.Effects.Supervisor,
      fn -> Cranium.Effects.RoomSummarizer.generate(room_id) end,
      restart: :temporary
    )

    :ok
  end
end
