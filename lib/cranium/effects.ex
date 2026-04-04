defmodule Cranium.Effects do
  @moduledoc """
  Post-inference effects domain.

  Supervises two children:
  - `PassReactor` — GenServer subscribing to pass_complete events,
    handling synchronous Store mutations and backpressure signaling.
  - `TaskSupervisor` — Task.Supervisor for fire-and-forget async work
    (handoff generation, summary generation).

  Convenience functions for spawning async tasks live here.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Cranium.Effects.TaskSupervisor},
      Cranium.Effects.PassReactor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Async task convenience functions ---

  @doc """
  Generate a handoff document for a conversation.

  Spawns a Task under the Effects TaskSupervisor. Returns immediately.
  """
  @spec generate_handoff(String.t(), String.t(), String.t() | nil) :: :ok
  def generate_handoff(conversation_id, epoch_id, cc_session_id) do
    Task.Supervisor.start_child(
      Cranium.Effects.TaskSupervisor,
      fn -> Cranium.Effects.HandoffWriter.generate(conversation_id, epoch_id, cc_session_id) end,
      restart: :temporary
    )

    :ok
  end

  @doc """
  Generate a cross-conversation summary.

  Spawns a Task under the Effects TaskSupervisor. Returns immediately.
  """
  @spec generate_summary(String.t(), String.t() | nil) :: :ok
  def generate_summary(conversation_id, cc_session_id) do
    Logger.info("Generating summary", conversation_id: conversation_id, stage: :effects)

    Task.Supervisor.start_child(
      Cranium.Effects.TaskSupervisor,
      fn -> Cranium.Effects.ConversationSummarizer.generate(conversation_id, cc_session_id) end,
      restart: :temporary
    )

    :ok
  end
end
