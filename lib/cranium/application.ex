defmodule Cranium.Application do
  @moduledoc """
  OTP Application for Cranium.

  Supervision tree (rest_for_one — if Store crashes, downstream restarts):

      Cranium.Supervisor
      ├── Cranium.Store.Repo          # Ecto connection pool
      ├── Cranium.Store               # Storage service with soft locking
      ├── Cranium.TTS.Cache            # Ephemeral TTS audio buffer
      ├── Cranium.Ingress             # Input processing stage
      ├── Cranium.Context             # Context assembly stage
      ├── Cranium.Egress              # Output processing stage
      ├── Cranium.Effects.Supervisor  # Async side-effect tasks
      ├── Cranium.Epoch.Registry      # One-epoch-per-conversation enforcement
      └── Cranium.Epoch.Supervisor    # Per-conversation epoch processes

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

      # Pipeline stages
      Cranium.Ingress,
      Cranium.Context,
      Cranium.Egress,

      # Async effects (handoffs, summaries)
      {Task.Supervisor, name: Cranium.Effects.Supervisor},

      # Epoch management
      {Registry, keys: :unique, name: Cranium.Epoch.Registry},
      {DynamicSupervisor, name: Cranium.Epoch.Supervisor, strategy: :one_for_one},

      # HTTP transport
      {Bandit, plug: Cranium.Transport.HTTP, port: http_port()}
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
