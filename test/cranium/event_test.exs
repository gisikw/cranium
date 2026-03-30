defmodule Cranium.EventTest do
  use ExUnit.Case, async: true

  describe "broadcast scoping" do
    test "broadcast/1 dispatches to global only" do
      Registry.register(Cranium.StreamRegistry, {:global}, [])
      event = {:epoch_started, "conv-1", %{epoch_id: "e-1"}}

      Cranium.Event.broadcast(event)

      assert_received ^event
    end

    test "broadcast/2 dispatches to conversation and global" do
      Registry.register(Cranium.StreamRegistry, {:conversation, "conv-2"}, [])
      Registry.register(Cranium.StreamRegistry, {:global}, [])
      event = {:message_received, "conv-2", %{text: "hi", origin: nil, stream_id: "s-1"}}

      Cranium.Event.broadcast("conv-2", event)

      # Received on both topics
      assert_received ^event
      assert_received ^event
    end

    test "broadcast/3 dispatches to stream, conversation, and global" do
      Registry.register(Cranium.StreamRegistry, {:stream_raw, "s-3"}, [])
      Registry.register(Cranium.StreamRegistry, {:conversation, "conv-3"}, [])
      Registry.register(Cranium.StreamRegistry, {:global}, [])
      event = {:pass_complete, "conv-3", "s-3", %{saturation: 0.5, turn_count: 1, reason: :complete}}

      Cranium.Event.broadcast("s-3", "conv-3", event)

      assert_received ^event
      assert_received ^event
      assert_received ^event
    end

    test "broadcast/2 does not dispatch to unrelated conversation" do
      Registry.register(Cranium.StreamRegistry, {:conversation, "conv-other"}, [])
      event = {:epoch_cleared, "conv-4", %{epoch_id: "e-4", source: "api"}}

      Cranium.Event.broadcast("conv-4", event)

      refute_received ^event
    end
  end
end
