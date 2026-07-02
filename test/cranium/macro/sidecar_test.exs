defmodule Cranium.Macro.SidecarTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cranium.Macro.{Sidecar, State, Definition}

  @room "sidecar-test-room"

  defp make_sidecar_macro(overrides \\ %{}) do
    base = %Definition{
      name: "test-sidecar",
      description: "A macro with sidecar learning",
      trigger: :match,
      match_config: %{patterns: ["test"], once: false},
      advertising: :hidden,
      lifecycle: :condition,
      learning: :sidecar,
      sidecar_config: %{model: nil, interval: 3, prompt: "Evaluate: %{conditions}\n%{lookback}"},
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Sidecar macro active", tag: nil, priority: 50},
      conditions: [
        %{description: "User confirmed item A", section: nil},
        %{description: "User confirmed item B", section: nil},
        %{description: "User confirmed item C", section: nil}
      ]
    }

    struct!(base, Map.to_list(overrides))
  end

  defp context(turn_count \\ 1) do
    %{
      conversation_id: @room,
      epoch_id: "epoch-1",
      turn_count: turn_count,
      message_text: "test message",
      room_name: @room
    }
  end

  setup do
    # Clear sidecar tracking state
    Sidecar.reset("test-sidecar", @room)
    # Clear macro state
    State.clear_session(@room)
    :ok
  end

  # --- in_flight?/2 ---

  describe "in_flight?/2" do
    test "returns false when no dispatch has happened" do
      refute Sidecar.in_flight?("test-sidecar", @room)
    end

    test "returns true when manually set via ETS" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: true, result: nil}}
      )

      assert Sidecar.in_flight?("test-sidecar", @room)
    end
  end

  # --- consume/2 ---

  describe "consume/2" do
    test "returns :none when no results pending" do
      assert :none = Sidecar.consume("test-sidecar", @room)
    end

    test "returns :none when in-flight with no result" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: true, result: nil}}
      )

      assert :none = Sidecar.consume("test-sidecar", @room)
    end

    test "returns and clears completed results" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: false, result: [0, 2]}}
      )

      assert {:ok, [0, 2]} = Sidecar.consume("test-sidecar", @room)

      # Consumed — should be cleared
      assert :none = Sidecar.consume("test-sidecar", @room)
      refute Sidecar.in_flight?("test-sidecar", @room)
    end

    test "clears result atomically" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: false, result: [1]}}
      )

      # First consume gets the result
      assert {:ok, [1]} = Sidecar.consume("test-sidecar", @room)

      # Second consume finds nothing
      assert :none = Sidecar.consume("test-sidecar", @room)
    end
  end

  # --- reset/2 ---

  describe "reset/2" do
    test "clears all tracking state" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: true, result: [0]}}
      )

      Sidecar.reset("test-sidecar", @room)

      refute Sidecar.in_flight?("test-sidecar", @room)
      assert :none = Sidecar.consume("test-sidecar", @room)
    end
  end

  # --- dispatch/3 guard conditions ---

  describe "dispatch/3 guards" do
    test "skips when already in flight" do
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{@room, "test-sidecar"}, %{in_flight: true, result: nil}}
      )

      macro = make_sidecar_macro()

      # Set up active state with conditions
      State.put_state("test-sidecar", @room, %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      assert {:skipped, :in_flight} = Sidecar.dispatch(macro, @room, context(10))
    end

    test "skips when interval not met" do
      macro = make_sidecar_macro()

      # Active since turn 5, interval=3, current turn=6 (only 1 turn since activation)
      State.put_state("test-sidecar", @room, %{
        "active" => true,
        "activated_at_turn" => 5,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"}
        ]
      })

      assert {:skipped, :interval_not_met} = Sidecar.dispatch(macro, @room, context(6))
    end

    test "skips when no remaining conditions" do
      macro = make_sidecar_macro()

      # All conditions complete
      State.put_state("test-sidecar", @room, %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "complete"},
          %{"index" => 1, "status" => "complete"},
          %{"index" => 2, "status" => "complete"}
        ]
      })

      assert {:skipped, :no_remaining_conditions} = Sidecar.dispatch(macro, @room, context(10))
    end

    test "skips when interval satisfied via last_eval_turn" do
      macro = make_sidecar_macro()

      # Activated at turn 0, last eval at turn 7, interval=3, current=8 (only 1 since last eval)
      State.put_state("test-sidecar", @room, %{
        "active" => true,
        "activated_at_turn" => 0,
        "last_eval_turn" => 7,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"}
        ]
      })

      assert {:skipped, :interval_not_met} = Sidecar.dispatch(macro, @room, context(8))
    end
  end

  # --- remaining_conditions filtering ---

  describe "condition filtering" do
    test "pending and skipped conditions are included in remaining" do
      macro = make_sidecar_macro()

      # Mix of statuses — only complete should be excluded
      State.put_state("test-sidecar", @room, %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "complete"},
          %{"index" => 1, "status" => "pending"},
          %{"index" => 2, "status" => "skipped"}
        ]
      })

      # Should NOT skip for no_remaining_conditions since indices 1,2 are still remaining
      # (Will skip for in_flight=false + interval not met at turn 1, but not for no conditions)
      result = Sidecar.dispatch(macro, @room, context(1))

      # At turn 1 with activated_at_turn 0, turns_since=1 < interval=3
      assert {:skipped, :interval_not_met} = result
    end
  end
end
