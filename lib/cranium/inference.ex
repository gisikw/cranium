defmodule Cranium.Inference do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Nix devShell env cache (ETS table for PATH injection into ClaudeCode backend)
      Cranium.Inference.NixEnv,

      # Singleton providers (SystemPrompt, History, Landscape)
      Cranium.Inference.TurnAssembly,

      # Per-conversation process lookup
      {Registry, keys: :unique, name: Cranium.Inference.ConversationRegistry},

      # Per-conversation supervisor pairs (TurnAssembler + Harness)
      {DynamicSupervisor, name: Cranium.Inference.ConversationDynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
