defmodule Cranium.Plugins.Ensemble.Evaluators.TurnGated do
  @moduledoc """
  Evaluator that blocks a candidate until a turn threshold, then enables it.

  ## Config

      evaluator_config:
        threshold: 5          # required — turn at which candidate becomes eligible
        confidence: 1.0       # optional, defaults to 1.0

  Returns 0.0 (ineligible) when `turn_count < threshold`, then returns
  `confidence` from that turn onward. Pairs with `Always` to create
  "force profile X for N turns, then split evenly" patterns.
  """

  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(metadata, config) do
    config = config || %{}
    threshold = config["threshold"] || 5

    if metadata.turn_count < threshold do
      0.0
    else
      config["confidence"] || 1.0
    end
  end
end
