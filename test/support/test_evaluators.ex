defmodule Cranium.TestEvaluators.AlwaysOne do
  @moduledoc "Test evaluator that always returns 1.0."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: 1.0
end

defmodule Cranium.TestEvaluators.AlwaysHalf do
  @moduledoc "Test evaluator that always returns 0.5."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: 0.5
end

defmodule Cranium.TestEvaluators.AlwaysZero do
  @moduledoc "Test evaluator that always returns 0.0 (ineligible)."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: 0.0
end

defmodule Cranium.TestEvaluators.Crasher do
  @moduledoc "Test evaluator that raises."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: raise("intentional evaluator crash")
end

defmodule Cranium.TestEvaluators.OverOne do
  @moduledoc "Test evaluator that returns > 1.0 (should be clamped)."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: 5.0
end

defmodule Cranium.TestEvaluators.Negative do
  @moduledoc "Test evaluator that returns negative (should be clamped to 0.0)."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(_metadata, _config), do: -1.0
end

defmodule Cranium.TestEvaluators.TurnBased do
  @moduledoc "Test evaluator that scores based on turn count."
  @behaviour Cranium.Plugins.Ensemble.Evaluator

  @impl true
  def confidence(metadata, config) do
    threshold = (config || %{})["threshold"] || 5

    if metadata.turn_count < threshold do
      1.0
    else
      0.2
    end
  end
end
