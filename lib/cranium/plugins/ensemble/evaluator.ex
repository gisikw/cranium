defmodule Cranium.Plugins.Ensemble.Evaluator do
  @moduledoc """
  Behaviour for ensemble candidate evaluators.

  An evaluator is a stateless module that scores a candidate profile's fitness
  for the current turn. The score (0.0-1.0) feeds into the ensemble's weighted
  selection algorithm.

  ## Example

      defmodule MyEvaluator do
        @behaviour Cranium.Plugins.Ensemble.Evaluator

        @impl true
        def confidence(metadata, _config) do
          if metadata.turn_count < 5, do: 1.0, else: 0.5
        end
      end

  Evaluators must be fast — they run synchronously in the turn assembly path.
  Expensive checks (health pings, model availability) should be cached or
  sampled, not computed per turn.
  """

  @type metadata :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          turn_count: non_neg_integer(),
          current_profile: String.t(),
          current_backend: atom(),
          current_model: String.t() | nil
        }

  @doc """
  Compute a confidence score for a candidate.

  Returns a float in [0.0, 1.0] where:
  - 0.0 = ineligible (will never be selected regardless of temperature)
  - 1.0 = fully confident (maximum weight in selection)

  Scores outside this range are clamped with a warning log.
  """
  @callback confidence(metadata(), config :: map() | nil) :: float()
end
