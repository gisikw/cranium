defmodule Cranium.Application do
  @moduledoc """
  OTP Application for Cranium.

  Supervision tree (rest_for_one — if Store crashes, downstream restarts):

      Cranium.Supervisor
      ├── Cranium.Store.Repo          # Ecto connection pool
      ├── Cranium.Store               # Storage service with soft locking
      ├── Cranium.TTS.Cache           # Ephemeral TTS audio buffer
      ├── Cranium.Context.Landscape   # Cross-conversation summary cache
      ├── Cranium.Ingress             # Input processing stage (legacy)
      ├── Cranium.Effects.Supervisor  # Async side-effect tasks
      ├── Cranium.Epoch.Registry      # One-epoch-per-conversation enforcement
      ├── Cranium.Epoch.Supervisor    # Per-conversation epoch processes
      ├── Cranium.Events              # Registry-based pub/sub
      ├── Cranium.Transport           # Wire protocol actors
      ├── Cranium.Media               # Media processing actors
      │   ├── Storage
      │   ├── Transcoder
      │   ├── TakeCollector
      │   └── OutputSegmenter
      ├── Cranium.Persistence         # Temporal state actors
      └── Cranium.Inference           # Inference actors
          ├── TurnAssembly            # Singleton providers
          │   ├── SystemPrompt
          │   └── History
          ├── ConversationRegistry    # Per-conversation process lookup
          └── ConversationDynamicSupervisor
              └── per conversation:
                  Conversation (:one_for_all)
                  ├── TurnAssembler
                  └── Harness

  Agent processes are started per-epoch (inside Epoch), not as top-level
  children. Transports (Matrix, Hearth) will be added as children once
  implemented.
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

      # Manifest registry (segment playlist for active streams)
      Cranium.Manifest,

      # TTS audio cache (ephemeral buffer between Synthesizer and HTTP transport)
      Cranium.TTS.Cache,

      # TTS warm queue (serializes synthesis to avoid GPU contention)
      Cranium.TTS.Warmer,

      # Input protocol (chunked audio take registry)
      Cranium.Input.TakeRegistry,

      # Nix devShell env cache (ETS table for PATH injection)
      Cranium.NixEnv,

      # Context providers (GenServer processes, started before Context stage)
      Cranium.Context.Landscape,

      # Stream event registry (duplicate-key Registry for pub/sub fanout)
      {Registry, keys: :duplicate, name: Cranium.StreamRegistry},

      # Pipeline stages (legacy — Ingress to be dissolved into actors)
      Cranium.Ingress,

      # Async effects (handoffs, summaries)
      {Task.Supervisor, name: Cranium.Effects.Supervisor},

      # Epoch management
      {Registry, keys: :unique, name: Cranium.Epoch.Registry},
      {DynamicSupervisor, name: Cranium.Epoch.Supervisor, strategy: :one_for_one},

      # HTTP transport (Bandit doesn't depend on Events, so it can start early)
      {Bandit, plug: Cranium.LegacyTransport.HTTP, port: http_port()},

      # Revised Hierarchy
      Cranium.Events,

      # Legacy transport bridge (must start after Events)
      Cranium.LegacyTransport,
      Cranium.Transport,
      Cranium.Media,
      Cranium.Persistence,
      Cranium.Inference
    ]

    opts = [strategy: :rest_for_one, name: Cranium.Supervisor]

    # Register built-in tools
    Cranium.Agent.ToolRouter.register("subagent", Cranium.Agent.Tools.Subagent)

    Supervisor.start_link(children, opts)
  end

  defp http_port do
    Application.get_env(:cranium, :http_port, 4000)
  end
end
