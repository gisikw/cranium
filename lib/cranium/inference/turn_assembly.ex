defmodule Cranium.Inference.TurnAssembly do
  @moduledoc """
  Supervisor for singleton context providers.

  SystemPrompt and Landscape are shared across all conversations — they
  cache globally and serve any TurnAssembler that calls them. History is
  a pure function module (no process).

  TurnAssembler itself is per-conversation, started by Conversation
  supervisors under ConversationDynamicSupervisor.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cranium.Inference.SystemPrompt,
      Cranium.Inference.Landscape
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
