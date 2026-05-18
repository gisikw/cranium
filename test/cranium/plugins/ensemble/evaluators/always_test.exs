defmodule Cranium.Plugins.Ensemble.Evaluators.AlwaysTest do
  use ExUnit.Case, async: true

  alias Cranium.Plugins.Ensemble.Evaluators.Always

  @metadata %{
    conversation_id: "test",
    epoch_id: "00000000-0000-0000-0000-000000000000",
    turn_count: 0,
    current_profile: "exo",
    current_backend: :claudecode,
    current_model: "claude-opus-4-6"
  }

  test "defaults to 1.0 with no config" do
    assert Always.confidence(@metadata, nil) == 1.0
    assert Always.confidence(@metadata, %{}) == 1.0
  end

  test "returns configured confidence" do
    assert Always.confidence(@metadata, %{"confidence" => 0.8}) == 0.8
    assert Always.confidence(@metadata, %{"confidence" => 0.0}) == 0.0
  end

  test "ignores turn count" do
    meta_10 = %{@metadata | turn_count: 10}
    meta_100 = %{@metadata | turn_count: 100}
    assert Always.confidence(meta_10, nil) == 1.0
    assert Always.confidence(meta_100, %{"confidence" => 0.5}) == 0.5
  end
end
