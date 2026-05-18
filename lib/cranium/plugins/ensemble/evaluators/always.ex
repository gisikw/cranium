defmodule Cranium.Plugins.Ensemble.Evaluators.Always do
  @moduledoc """
  Evaluator that returns a fixed confidence score every turn.

  ## Config

      evaluator_config:
        confidence: 0.8   # defaults to 1.0

  Useful as the "anchor" candidate in an ensemble — always eligible,
  always at the same weight.
  """

  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, config) do
    (config || %{})["confidence"] || 1.0
  end
end
