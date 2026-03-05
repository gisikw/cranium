defmodule Cranium.Application do
  @moduledoc """
  OTP Application for Cranium.

  Supervision tree (rest_for_one — if Store crashes, downstream restarts):

      Cranium.Supervisor
      ├── Cranium.Store.Repo          # Ecto connection pool
      ├── Cranium.Store               # Storage service with soft locking
      ├── Cranium.Ingress             # Input processing stage
      ├── Cranium.Context             # Context assembly stage
      ├── Cranium.Egress              # Output processing stage
      ├── Cranium.Effects.Supervisor  # Async side-effect tasks
      ├── Cranium.Session.Registry    # One-session-per-room enforcement
      └── Cranium.Session.Supervisor  # Per-room session processes

  Agent processes are started per-session (inside Session), not as top-level
  children. Transports (Matrix, Hearth) will be added as children once
  implemented.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Storage — must start first (downstream stages depend on it)
      Cranium.Store.Repo,
      Cranium.Store,

      # Pipeline stages
      Cranium.Ingress,
      Cranium.Context,
      Cranium.Egress,

      # Async effects (handoffs, summaries)
      {DynamicSupervisor, name: Cranium.Effects.Supervisor, strategy: :one_for_one},

      # Session management
      {Registry, keys: :unique, name: Cranium.Session.Registry},
      {DynamicSupervisor, name: Cranium.Session.Supervisor, strategy: :one_for_one}

      # Transports — uncomment when implemented
      # Cranium.Transport.Matrix,
    ]

    opts = [strategy: :rest_for_one, name: Cranium.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
