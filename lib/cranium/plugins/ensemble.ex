defmodule Cranium.Plugins.Ensemble do
  @moduledoc """
  Dynamic multi-profile routing with pluggable confidence evaluation.

  Manages a set of candidate profiles, each paired with an evaluator module
  that scores fitness for the current turn. Per turn, collects confidence
  scores, normalizes into a probability distribution via temperature scaling,
  and samples to select which profile handles inference.

  ## Configuration

  In profiles.yaml:

      plugins:
        - module: Cranium.Plugins.Ensemble
          config:
            temperature: 1.0
            seed: 42           # optional, for deterministic selection
            candidates:
              - profile: exo
                evaluator: Cranium.Plugins.Ensemble.Evaluators.Always
              - profile: exo-local
                evaluator: Cranium.Plugins.Ensemble.Evaluators.Saturation
                evaluator_config:
                  threshold: 0.6

  ## Selection algorithm

  1. Each candidate's evaluator produces a confidence score in [0.0, 1.0]
  2. Scores are temperature-scaled: weight = confidence^(1/T)
  3. Zero-confidence candidates are excluded (ineligible)
  4. Weights are normalized to a probability distribution
  5. A candidate is sampled from the distribution

  Temperature controls sharpness:
  - T < 1.0: winner-take-all tendency
  - T = 1.0: linear proportional to confidence
  - T > 1.0: flattens toward uniform
  """

  @behaviour Cranium.Plugin

  require Logger

  @impl true
  def init(metadata) do
    config = metadata.plugin_config || %{}
    raw_candidates = config["candidates"]

    with {:ok, candidates} <- validate_candidates(raw_candidates) do
      temperature = config["temperature"] || 1.0

      rng_state =
        case config["seed"] do
          nil -> :rand.seed_s(:exsss)
          seed when is_integer(seed) -> :rand.seed_s(:exsss, seed)
        end

      state = %{
        candidates: candidates,
        temperature: temperature,
        rng_state: rng_state,
        history: [],
        last_selection: nil
      }

      {:ok, [:after_resolve_profile, :after_pass_complete], state}
    else
      {:error, reason} ->
        Logger.warning("Ensemble: init failed, ignoring session",
          reason: reason,
          conversation_id: metadata.conversation_id
        )

        :ignore
    end
  end

  @impl true
  def after_resolve_profile(context, state) do
    metadata = %{
      conversation_id: context.conversation_id,
      epoch_id: context.epoch_id,
      turn_count: context.turn_count,
      current_profile: context.profile_name,
      current_backend: context.backend,
      current_model: context.model
    }

    # Evaluate all candidates
    scored =
      Enum.map(state.candidates, fn candidate ->
        confidence = evaluate_candidate(candidate, metadata)
        {candidate, confidence}
      end)

    # Temperature scaling and normalization
    case select(scored, state.temperature, state.rng_state) do
      {:ok, selected_profile, scored_candidates, new_rng} ->
        final_context =
          if selected_profile == context.profile_name do
            # Same profile — no swap needed
            context
          else
            case swap_profile(context, selected_profile) do
              {:ok, new_context} ->
                new_context

              {:error, reason} ->
                Logger.warning("Ensemble: profile swap failed, keeping default",
                  target: selected_profile,
                  reason: inspect(reason)
                )

                context
            end
          end

        state = %{
          state
          | rng_state: new_rng,
            last_selection: %{
              profile: final_context.profile_name,
              selected_profile: selected_profile,
              model: final_context.model,
              backend: to_string(final_context.backend),
              scores: scored_candidates
            }
        }

        {:ok, final_context, state}

      :no_eligible ->
        Logger.warning("Ensemble: all candidates ineligible, keeping default",
          profile: context.profile_name
        )

        {:ok, context, state}
    end
  end

  @impl true
  def after_pass_complete(pass_context, state) do
    case state.last_selection do
      nil ->
        {:ok, state}

      selection ->
        record = %{
          turn_count: pass_context.turn_count,
          selected_profile: selection.profile,
          scores: selection.scores
        }

        Cranium.Store.save_ensemble_selection(%{
          epoch_id: pass_context.epoch_id,
          turn_count: pass_context.turn_count,
          profile: selection.profile,
          model: selection.model,
          backend: selection.backend,
          scores: encode_scores(selection.scores)
        })

        {:ok, %{state | history: [record | state.history], last_selection: nil}}
    end
  end

  # --- Private ---

  defp encode_scores(scores) when is_list(scores) do
    Enum.map(scores, fn s ->
      %{
        "profile" => s.profile,
        "confidence" => s.confidence,
        "weight" => s.weight
      }
    end)
  end

  defp encode_scores(_), do: nil

  defp validate_candidates(nil), do: {:error, :no_candidates}
  defp validate_candidates(cs) when length(cs) < 2, do: {:error, :too_few_candidates}

  defp validate_candidates(candidates) when is_list(candidates) do
    parsed =
      Enum.reduce_while(candidates, {:ok, []}, fn raw, {:ok, acc} ->
        with {:ok, candidate} <- parse_candidate(raw) do
          {:cont, {:ok, [candidate | acc]}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)

    case parsed do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_candidates(_), do: {:error, :invalid_candidates}

  defp parse_candidate(%{"profile" => profile, "evaluator" => evaluator_str} = raw)
       when is_binary(profile) and is_binary(evaluator_str) do
    case resolve_evaluator(evaluator_str) do
      {:ok, module} ->
        {:ok,
         %{
           profile: profile,
           evaluator: module,
           evaluator_config: raw["evaluator_config"]
         }}

      {:error, _} = err ->
        err
    end
  end

  defp parse_candidate(%{profile: profile, evaluator: module} = raw)
       when is_binary(profile) and is_atom(module) do
    {:ok,
     %{
       profile: profile,
       evaluator: module,
       evaluator_config: raw[:evaluator_config]
     }}
  end

  defp parse_candidate(_), do: {:error, :invalid_candidate_declaration}

  defp resolve_evaluator(module_str) when is_binary(module_str) do
    module =
      module_str
      |> String.trim_leading("Elixir.")
      |> then(&"Elixir.#{&1}")
      |> String.to_existing_atom()

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :confidence, 2) do
          {:ok, module}
        else
          {:error, {:evaluator_not_implemented, module_str}}
        end

      {:error, _} ->
        {:error, {:evaluator_not_loaded, module_str}}
    end
  rescue
    ArgumentError -> {:error, {:evaluator_not_found, module_str}}
  end

  defp evaluate_candidate(candidate, metadata) do
    score = candidate.evaluator.confidence(metadata, candidate.evaluator_config)

    cond do
      score < 0.0 ->
        Logger.warning("Ensemble: evaluator returned negative score, clamping to 0.0",
          evaluator: inspect(candidate.evaluator),
          profile: candidate.profile,
          raw_score: score
        )

        0.0

      score > 1.0 ->
        Logger.warning("Ensemble: evaluator returned score > 1.0, clamping to 1.0",
          evaluator: inspect(candidate.evaluator),
          profile: candidate.profile,
          raw_score: score
        )

        1.0

      true ->
        score
    end
  rescue
    e ->
      Logger.warning("Ensemble: evaluator crashed, scoring 0.0",
        evaluator: inspect(candidate.evaluator),
        profile: candidate.profile,
        error: Exception.message(e)
      )

      0.0
  end

  defp select(scored, temperature, rng_state) do
    # Apply temperature scaling: weight = confidence^(1/T)
    weighted =
      Enum.map(scored, fn {candidate, confidence} ->
        weight =
          if confidence == 0.0 do
            0.0
          else
            :math.pow(confidence, 1.0 / temperature)
          end

        %{
          profile: candidate.profile,
          confidence: confidence,
          weight: weight
        }
      end)

    # Filter eligible
    eligible = Enum.filter(weighted, &(&1.weight > 0.0))

    case eligible do
      [] ->
        :no_eligible

      _ ->
        # Normalize
        total = Enum.reduce(eligible, 0.0, &(&1.weight + &2))

        normalized =
          Enum.map(weighted, fn sc ->
            if sc.weight > 0.0 do
              %{sc | weight: sc.weight / total}
            else
              sc
            end
          end)

        # Weighted sample
        {rand_val, new_rng} = :rand.uniform_s(rng_state)
        selected = weighted_sample(eligible, total, rand_val)

        {:ok, selected, normalized, new_rng}
    end
  end

  defp weighted_sample(eligible, total, rand_val) do
    threshold = rand_val * total

    {selected, _} =
      Enum.reduce_while(eligible, {nil, 0.0}, fn candidate, {_, cumulative} ->
        new_cumulative = cumulative + candidate.weight

        if new_cumulative >= threshold do
          {:halt, {candidate.profile, new_cumulative}}
        else
          {:cont, {candidate.profile, new_cumulative}}
        end
      end)

    selected
  end

  defp swap_profile(context, target_profile) do
    case Cranium.Config.resolve_profile(target_profile) do
      {:ok, resolved} ->
        {:ok,
         %{
           context
           | profile_name: resolved.name,
             backend: resolved.backend,
             backend_module: resolved.backend_module,
             model: resolved.model,
             identity: resolved.identity,
             thinking: resolved.thinking,
             context_window: resolved.context_window,
             saturation_warn: resolved.saturation_warn,
             saturation_critical: resolved.saturation_critical
         }}

      {:error, _} = err ->
        err
    end
  end
end
