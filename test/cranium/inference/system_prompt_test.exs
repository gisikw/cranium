defmodule Cranium.Inference.SystemPromptTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Inference.SystemPrompt

  @moduletag :capture_log

  describe "contribute/2" do
    test "returns cached identity when not fresh" do
      result = SystemPrompt.contribute("test-convo", is_fresh: false)
      assert is_binary(result)
    end

    test "uses identity override when provided" do
      result = SystemPrompt.contribute("test-convo",
        is_fresh: false,
        identity: "You are a test agent."
      )

      assert result == "You are a test agent."
    end

    test "ignores empty identity override" do
      result = SystemPrompt.contribute("test-convo",
        is_fresh: false,
        identity: ""
      )

      # Should fall back to cached identity, not empty string override
      assert is_binary(result)
    end

    test "includes handoff on fresh epoch when handoff exists" do
      conversation_id = "test-handoff-#{System.unique_integer([:positive])}"

      # Store a handoff on a previous epoch
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      Cranium.Store.save_handoff(epoch_id, "Previous session context here.")

      result = SystemPrompt.contribute(conversation_id,
        is_fresh: true,
        identity: "Base identity."
      )

      assert result =~ "Base identity."
      assert result =~ "<room-handoff>"
      assert result =~ "Previous session context here."
      assert result =~ "</room-handoff>"
    end

    test "no handoff block on non-fresh epoch" do
      conversation_id = "test-no-handoff-#{System.unique_integer([:positive])}"

      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      Cranium.Store.save_handoff(epoch_id, "Should not appear.")

      result = SystemPrompt.contribute(conversation_id,
        is_fresh: false,
        identity: "Base identity."
      )

      assert result == "Base identity."
      refute result =~ "<room-handoff>"
    end

    test "no handoff block when no handoff exists" do
      conversation_id = "test-empty-handoff-#{System.unique_integer([:positive])}"

      result = SystemPrompt.contribute(conversation_id,
        is_fresh: true,
        identity: "Base identity."
      )

      assert result == "Base identity."
      refute result =~ "<room-handoff>"
    end
  end
end
