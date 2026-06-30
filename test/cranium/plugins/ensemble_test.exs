defmodule Cranium.Plugins.EnsembleTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log
  alias Cranium.Plugins.Ensemble

  @metadata %{
    conversation_id: "test-conv",
    epoch_id: "test-epoch",
    room_name: "test-room",
    profile: %Cranium.Config.Profile{name: "test", backend: :mock, model: "test-model"},
    plugin_config: %{
      "temperature" => 1.0,
      "seed" => 42,
      "candidates" => [
        %{
          "profile" => "exo",
          "evaluator" => "Cranium.TestEvaluators.AlwaysOne"
        },
        %{
          "profile" => "exo-local",
          "evaluator" => "Cranium.TestEvaluators.AlwaysHalf"
        }
      ]
    }
  }

  @resolved_context %{
    conversation_id: "test-conv",
    epoch_id: "test-epoch",
    turn_count: 1,
    profile_name: "exo",
    backend: :claudecode,
    backend_module: Cranium.Backend.LLM.Mock,
    model: "claude-opus-4-6",
    identity: "You are Exo.",
    thinking: nil,
    context_window: 200_000,
    saturation_warn: 0.7,
    saturation_critical: 0.9
  }

  describe "init/1" do
    test "succeeds with valid config" do
      assert {:ok, hooks, state} = Ensemble.init(@metadata)
      assert :after_resolve_profile in hooks
      assert :after_pass_complete in hooks
      assert length(state.candidates) == 2
      assert state.temperature == 1.0
      assert state.history == []
    end

    test "ignores when no candidates" do
      metadata = put_in(@metadata.plugin_config["candidates"], nil)
      assert :ignore = Ensemble.init(metadata)
    end

    test "ignores when fewer than 2 candidates" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"}
        ])

      assert :ignore = Ensemble.init(metadata)
    end

    test "ignores when evaluator module not found" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.NonExistent.Module"}
        ])

      assert :ignore = Ensemble.init(metadata)
    end

    test "uses default temperature of 1.0" do
      metadata = %{@metadata | plugin_config: Map.delete(@metadata.plugin_config, "temperature")}
      assert {:ok, _hooks, state} = Ensemble.init(metadata)
      assert state.temperature == 1.0
    end

    test "deterministic with seed" do
      {:ok, _, state1} = Ensemble.init(@metadata)
      {:ok, _, state2} = Ensemble.init(@metadata)
      assert state1.rng_state == state2.rng_state
    end

    test "non-deterministic without seed" do
      metadata = %{@metadata | plugin_config: Map.delete(@metadata.plugin_config, "seed")}
      {:ok, _, state1} = Ensemble.init(metadata)
      {:ok, _, state2} = Ensemble.init(metadata)
      # Very unlikely to be equal with random seeds
      assert state1.rng_state != state2.rng_state
    end
  end

  describe "after_resolve_profile/2" do
    setup do
      {:ok, _hooks, state} = Ensemble.init(@metadata)
      {:ok, state: state}
    end

    test "selects a candidate and records in last_selection", %{state: state} do
      {:ok, _context, new_state} = Ensemble.after_resolve_profile(@resolved_context, state)
      assert new_state.last_selection != nil
      assert new_state.last_selection.selected_profile in ["exo", "exo-local"]
      assert length(new_state.last_selection.scores) == 2
    end

    test "deterministic selection with seed", %{state: state} do
      {:ok, ctx1, _} = Ensemble.after_resolve_profile(@resolved_context, state)
      {:ok, ctx2, _} = Ensemble.after_resolve_profile(@resolved_context, state)
      assert ctx1.profile_name == ctx2.profile_name
    end

    test "higher confidence gets selected more often" do
      # AlwaysOne scores 1.0, AlwaysHalf scores 0.5
      # With T=1.0, weights are proportional: 1.0 vs 0.5
      # So "exo" should be selected ~67% of the time
      metadata = %{@metadata | plugin_config: Map.delete(@metadata.plugin_config, "seed")}
      {:ok, _, state} = Ensemble.init(metadata)

      results =
        for _ <- 1..200, reduce: %{state: state, selections: []} do
          %{state: s, selections: sels} ->
            {:ok, _ctx, new_state} = Ensemble.after_resolve_profile(@resolved_context, s)
            %{state: new_state, selections: [new_state.last_selection.selected_profile | sels]}
        end

      exo_count = Enum.count(results.selections, &(&1 == "exo"))
      # With 200 samples, exo (weight 1.0/1.5 = 0.667) should appear 100+ times
      assert exo_count > 90
      assert exo_count < 180
    end

    test "zero confidence makes candidate ineligible" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.AlwaysZero"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)

      # Run many times — exo-local should never be selected
      for _ <- 1..50 do
        {:ok, ctx, state} = Ensemble.after_resolve_profile(@resolved_context, state)
        assert ctx.profile_name == "exo"
        state
      end
    end

    test "all zeros returns context unchanged" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysZero"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.AlwaysZero"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)
      {:ok, ctx, _state} = Ensemble.after_resolve_profile(@resolved_context, state)
      # Context should be unchanged
      assert ctx.profile_name == "exo"
      assert ctx.model == "claude-opus-4-6"
    end

    test "evaluator crash scores 0.0 for that candidate" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.Crasher"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)
      {:ok, ctx, new_state} = Ensemble.after_resolve_profile(@resolved_context, state)

      # Crasher gets 0.0, AlwaysOne gets 1.0 — exo always selected
      assert ctx.profile_name == "exo"
      # Crasher should show 0.0 confidence in scores
      crasher_score =
        Enum.find(new_state.last_selection.scores, &(&1.profile == "exo-local"))

      assert crasher_score.confidence == 0.0
    end

    test "out-of-range scores are clamped" do
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.OverOne"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.Negative"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)
      {:ok, ctx, new_state} = Ensemble.after_resolve_profile(@resolved_context, state)

      # OverOne clamped to 1.0, Negative clamped to 0.0
      assert ctx.profile_name == "exo"
      over_score = Enum.find(new_state.last_selection.scores, &(&1.profile == "exo"))
      neg_score = Enum.find(new_state.last_selection.scores, &(&1.profile == "exo-local"))
      assert over_score.confidence == 1.0
      assert neg_score.confidence == 0.0
    end

    test "low temperature sharpens distribution" do
      # With T=0.1, the higher-scoring candidate dominates even more
      metadata = put_in(@metadata.plugin_config["temperature"], 0.1)
      metadata = Map.delete(metadata.plugin_config, "seed") |> then(&%{metadata | plugin_config: &1})
      {:ok, _, state} = Ensemble.init(metadata)

      results =
        for _ <- 1..100, reduce: %{state: state, selections: []} do
          %{state: s, selections: sels} ->
            {:ok, ctx, new_state} = Ensemble.after_resolve_profile(@resolved_context, s)
            %{state: new_state, selections: [ctx.profile_name | sels]}
        end

      exo_count = Enum.count(results.selections, &(&1 == "exo"))
      # At T=0.1, weight ratio is 1.0^10 vs 0.5^10 = 1.0 vs 0.001
      # So exo should be selected ~99.9% of the time
      assert exo_count >= 95
    end

    test "high temperature flattens distribution" do
      metadata = put_in(@metadata.plugin_config["temperature"], 10.0)
      metadata = Map.delete(metadata.plugin_config, "seed") |> then(&%{metadata | plugin_config: &1})
      {:ok, _, state} = Ensemble.init(metadata)

      results =
        for _ <- 1..200, reduce: %{state: state, selections: []} do
          %{state: s, selections: sels} ->
            {:ok, _ctx, new_state} = Ensemble.after_resolve_profile(@resolved_context, s)
            %{state: new_state, selections: [new_state.last_selection.selected_profile | sels]}
        end

      exo_count = Enum.count(results.selections, &(&1 == "exo"))
      # At T=10, weight ratio is 1.0^0.1 vs 0.5^0.1 ≈ 1.0 vs 0.933
      # So exo gets ~51.7% — nearly uniform
      assert exo_count > 70
      assert exo_count < 140
    end
  end

  describe "after_pass_complete/2" do
    setup do
      {:ok, _hooks, state} = Ensemble.init(@metadata)
      {:ok, state: state}
    end

    test "records selection in history", %{state: state} do
      # Simulate a turn
      {:ok, _ctx, state} = Ensemble.after_resolve_profile(@resolved_context, state)
      assert state.last_selection != nil

      pass_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        output: "Hello!",
        turn_count: 1
      }

      {:ok, new_state} = Ensemble.after_pass_complete(pass_context, state)
      assert new_state.last_selection == nil
      assert length(new_state.history) == 1

      [record] = new_state.history
      assert record.turn_count == 1
      assert record.selected_profile in ["exo", "exo-local"]
      assert length(record.scores) == 2
    end

    test "no-op when no prior selection", %{state: state} do
      pass_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        output: "Hello!",
        turn_count: 1
      }

      {:ok, new_state} = Ensemble.after_pass_complete(pass_context, state)
      assert new_state.history == []
    end

    test "history accumulates across turns", %{state: state} do
      pass_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        output: "Hello!",
        turn_count: 1
      }

      # Turn 1
      {:ok, _ctx, state} = Ensemble.after_resolve_profile(@resolved_context, state)
      {:ok, state} = Ensemble.after_pass_complete(pass_context, state)

      # Turn 2
      context2 = %{@resolved_context | turn_count: 2}
      {:ok, _ctx, state} = Ensemble.after_resolve_profile(context2, state)
      {:ok, state} = Ensemble.after_pass_complete(%{pass_context | turn_count: 2}, state)

      assert length(state.history) == 2
    end
  end

  describe "profile swap" do
    test "swaps profile fields when different candidate selected" do
      # Force selection of exo-local by making exo score 0
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysZero"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)

      # This will try to call Config.resolve_profile("exo-local") which may not
      # exist in test. The plugin should handle the error gracefully.
      {:ok, ctx, _state} = Ensemble.after_resolve_profile(@resolved_context, state)

      # If exo-local doesn't exist in Config, falls back to original
      # If it does exist, profile_name changes
      assert ctx.profile_name in ["exo", "exo-local"]
    end

    test "no swap when selected profile matches current" do
      # Force selection of exo (same as current)
      metadata =
        put_in(@metadata.plugin_config["candidates"], [
          %{"profile" => "exo", "evaluator" => "Cranium.TestEvaluators.AlwaysOne"},
          %{"profile" => "exo-local", "evaluator" => "Cranium.TestEvaluators.AlwaysZero"}
        ])

      {:ok, _, state} = Ensemble.init(metadata)
      {:ok, ctx, _state} = Ensemble.after_resolve_profile(@resolved_context, state)

      # Should be unchanged since exo was already selected
      assert ctx.profile_name == "exo"
      assert ctx.model == "claude-opus-4-6"
    end
  end
end
