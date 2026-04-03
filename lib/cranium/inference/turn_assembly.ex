defmodule Cranium.Inference.TurnAssembly do
  @moduledoc """
  Supervisor for the turn assembly domain.

  Groups the actors responsible for collecting everything needed to build
  a complete inference turn: the assembler itself (correlates input) and
  the context providers it will eventually call directly.

  Epoch currently calls the providers (SystemPrompt, History) because it
  holds the state they need (turn_count, epoch_id). When Epoch's state
  management is externalized, TurnAssembler takes over those calls and
  this supervisor's call flow matches its supervision hierarchy.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cranium.Inference.SystemPrompt,
      Cranium.Inference.History,
      Cranium.Inference.TurnAssembler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
