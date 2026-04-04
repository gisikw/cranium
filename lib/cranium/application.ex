defmodule Cranium.Application do
  @moduledoc """
  OTP Application for Cranium.

  Supervision tree (rest_for_one — if Store crashes, downstream restarts):

      Cranium.Supervisor
      ├── Cranium.Drain               # SIGTERM graceful shutdown
      ├── Cranium.Store.Repo          # Ecto connection pool
      ├── Cranium.Store               # Storage service with soft locking
      ├── Cranium.Events              # Unified event pub/sub
      ├── Cranium.Effects              # Post-inference effects
      │   ├── TaskSupervisor          #   async (handoffs, summaries)
      │   └── PassReactor             #   sync (Store mutations, backpressure)
      ├── Cranium.Transport           # Wire protocol actors
      │   ├── SegmentRegistry
      │   ├── Manifest
      │   └── Bandit (Transport.HTTP)
      ├── Cranium.Media               # Media processing actors
      │   ├── Storage
      │   ├── Transcoder
      │   ├── TakeCollector
      │   ├── OutputSegmenter
      │   ├── TTS.Cache
      │   └── TTS.Warmer
      └── Cranium.Inference           # Inference actors
          ├── NixEnv                  # Nix devShell PATH cache (for ClaudeCode backend)
          ├── TurnAssembly            # Singleton providers
          │   ├── SystemPrompt
          │   ├── History
          │   └── Context.Landscape
          ├── ConversationRegistry    # Per-conversation process lookup
          └── ConversationDynamicSupervisor
              └── per conversation:
                  Conversation (:one_for_all)
                  ├── TurnAssembler
                  └── Harness

  Agent processes are started per-conversation (inside Harness), not as
  top-level children.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Drain coordinator — traps SIGTERM for graceful shutdown
      Cranium.Drain,

      # Storage — must start first (downstream stages depend on it)
      Cranium.Store.Repo,
      Cranium.Store,

      # Event registry (duplicate-key Registry for pub/sub fanout)
      # Must start before any actor that subscribes
      Cranium.Events,

      Cranium.Effects,
      Cranium.Transport,
      Cranium.Media,
      Cranium.Inference
    ]

    opts = [strategy: :rest_for_one, name: Cranium.Supervisor]

    # Register built-in tools
    Cranium.Agent.ToolRouter.register("subagent", Cranium.Agent.Tools.Subagent)

    Supervisor.start_link(children, opts)
  end
end
