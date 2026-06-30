defmodule Cranium.Plugins.Ensemble.Evaluators.TurnGatedTest do
  use ExUnit.Case, async: true

  alias Cranium.Plugins.Ensemble.Evaluators.TurnGated

  @metadata %{
    conversation_id: "test",
    epoch_id: "00000000-0000-0000-0000-000000000000",
    turn_count: 0,
    current_profile: "exo-local",
    current_backend: :mock,
    current_model: "gemma4-cranium"
  }

  test "returns 0.0 before threshold" do
    for turn <- 0..4 do
      meta = %{@metadata | turn_count: turn}
      assert TurnGated.confidence(meta, %{"threshold" => 5}) == 0.0
    end
  end

  test "returns 1.0 at threshold" do
    meta = %{@metadata | turn_count: 5}
    assert TurnGated.confidence(meta, %{"threshold" => 5}) == 1.0
  end

  test "returns 1.0 after threshold" do
    meta = %{@metadata | turn_count: 20}
    assert TurnGated.confidence(meta, %{"threshold" => 5}) == 1.0
  end

  test "defaults threshold to 5 with nil config" do
    assert TurnGated.confidence(%{@metadata | turn_count: 4}, nil) == 0.0
    assert TurnGated.confidence(%{@metadata | turn_count: 5}, nil) == 1.0
  end

  test "returns custom confidence after threshold" do
    config = %{"threshold" => 3, "confidence" => 0.7}
    assert TurnGated.confidence(%{@metadata | turn_count: 2}, config) == 0.0
    assert TurnGated.confidence(%{@metadata | turn_count: 3}, config) == 0.7
  end
end
