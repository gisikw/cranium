defmodule Cranium.Application do
  @moduledoc """
  OTP Application for Cranium.

  Supervision tree (rest_for_one — if Store crashes, downstream restarts):

      Cranium.Supervisor
      ├── Cranium.Store.Repo          # Ecto connection pool
      ├── Cranium.Store               # Storage service with soft locking
      ├── Cranium.TTS.Cache           # Ephemeral TTS audio buffer
      ├── Cranium.Context.Landscape   # Cross-conversation summary cache
      ├── Cranium.Effects.Supervisor  # Async side-effect tasks
      ├── Cranium.Events              # Unified event pub/sub
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

  Agent processes are started per-conversation (inside Harness), not as
  top-level children. Transports (Matrix, Hearth) will be added as
  children once implemented.
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

      # Input protocol (chunked audio take registry)
      Cranium.Input.TakeRegistry,

      # Nix devShell env cache (ETS table for PATH injection)
      Cranium.NixEnv,

      # Context providers (GenServer processes, started before Context stage)
      Cranium.Context.Landscape,

      # Event registry (duplicate-key Registry for pub/sub fanout)
      # Must start before any actor that subscribes
      Cranium.Events,

      # TTS audio cache (subscribes to segment_ready via Events)
      Cranium.TTS.Cache,

      # TTS warm queue (serializes synthesis to avoid GPU contention)
      Cranium.TTS.Warmer,

      # Async effects (handoffs, summaries)
      {Task.Supervisor, name: Cranium.Effects.Supervisor},

      # HTTP transport
      {Bandit, plug: Cranium.LegacyTransport.HTTP, port: http_port()},

      # Legacy transport bridge
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
