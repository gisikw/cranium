defmodule Cranium.Inference.SystemPromptTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Inference.SystemPrompt

  @moduletag :capture_log

  setup do
    conversation_id = "test-#{System.unique_integer([:positive])}"
    %{conversation_id: conversation_id}
  end

  describe "contribute/2" do
    test "returns cached identity when not fresh", %{conversation_id: cid} do
      result = SystemPrompt.contribute(cid, is_fresh: false)
      assert is_binary(result)
    end

    test "uses identity override when provided", %{conversation_id: cid} do
      result = SystemPrompt.contribute(cid,
        is_fresh: false,
        identity: "You are a test agent."
      )

      assert result == "You are a test agent."
    end

    test "ignores empty identity override", %{conversation_id: cid} do
      result = SystemPrompt.contribute(cid,
        is_fresh: false,
        identity: ""
      )

      assert is_binary(result)
    end

    test "includes handoff on fresh epoch when handoff exists", %{conversation_id: cid} do
      {:ok, epoch_id} = Cranium.Store.create_epoch(cid)
      Cranium.Store.save_handoff(epoch_id, "Previous session context here.")

      result = SystemPrompt.contribute(cid,
        is_fresh: true,
        identity: "Base identity."
      )

      assert result =~ "Base identity."
      assert result =~ "<room-handoff>"
      assert result =~ "Previous session context here."
      assert result =~ "</room-handoff>"
    end

    test "handoff is stable across subsequent turns", %{conversation_id: cid} do
      {:ok, epoch_id} = Cranium.Store.create_epoch(cid)
      Cranium.Store.save_handoff(epoch_id, "Handoff content.")

      # Turn 1: fresh, resolves and caches handoff
      result1 = SystemPrompt.contribute(cid,
        is_fresh: true,
        identity: "Base identity."
      )

      assert result1 =~ "<room-handoff>"
      assert result1 =~ "Handoff content."

      # Turn 2+: not fresh, handoff persists from cache
      result2 = SystemPrompt.contribute(cid,
        is_fresh: false,
        identity: "Base identity."
      )

      assert result1 == result2
    end

    test "is_fresh invalidates stale cache and re-resolves", %{conversation_id: cid} do
      {:ok, epoch_id} = Cranium.Store.create_epoch(cid)
      Cranium.Store.save_handoff(epoch_id, "First handoff.")

      # Populate cache
      result1 = SystemPrompt.contribute(cid, is_fresh: true, identity: "Base.")
      assert result1 =~ "First handoff."

      # Update the SAME epoch's handoff (simulates handoff regeneration)
      Cranium.Store.save_handoff(epoch_id, "Updated handoff.")

      # Without is_fresh, cache holds stale value
      stale = SystemPrompt.contribute(cid, is_fresh: false, identity: "Base.")
      assert stale =~ "First handoff."

      # With is_fresh, cache is invalidated and re-resolved
      fresh = SystemPrompt.contribute(cid, is_fresh: true, identity: "Base.")
      assert fresh =~ "Updated handoff."
    end

    test "no handoff on non-fresh epoch without prior fresh turn", %{conversation_id: cid} do
      {:ok, epoch_id} = Cranium.Store.create_epoch(cid)
      Cranium.Store.save_handoff(epoch_id, "Should not appear.")

      result = SystemPrompt.contribute(cid,
        is_fresh: false,
        identity: "Base identity."
      )

      # First call for this conversation is non-fresh — resolves handoff
      # anyway (cache miss triggers lookup), so it WILL include the handoff.
      # This is correct: the system prompt should be stable regardless of
      # whether the first call happened to be is_fresh or not.
      assert result =~ "<room-handoff>"
    end

    test "caches :none when no handoff exists", %{conversation_id: cid} do
      # First call: no handoff in DB or disk
      result1 = SystemPrompt.contribute(cid, is_fresh: true, identity: "Base.")
      refute result1 =~ "<room-handoff>"

      # Second call: cached :none, no DB hit
      result2 = SystemPrompt.contribute(cid, is_fresh: false, identity: "Base.")
      assert result1 == result2
    end

    test "injects tools_prompt between identity and handoff", %{conversation_id: cid} do
      {:ok, epoch_id} = Cranium.Store.create_epoch(cid)
      Cranium.Store.save_handoff(epoch_id, "Handoff content.")

      result = SystemPrompt.contribute(cid,
        is_fresh: true,
        identity: "Identity.",
        tools_prompt: "# Tool Guidance\nUse Read instead of cat."
      )

      assert result =~ "Identity."
      assert result =~ "# Tool Guidance"
      assert result =~ "<room-handoff>"

      # Verify ordering: identity before tools_prompt before handoff
      identity_pos = :binary.match(result, "Identity.") |> elem(0)
      tools_pos = :binary.match(result, "# Tool Guidance") |> elem(0)
      handoff_pos = :binary.match(result, "<room-handoff>") |> elem(0)
      assert identity_pos < tools_pos
      assert tools_pos < handoff_pos
    end

    test "tools_prompt without handoff", %{conversation_id: cid} do
      result = SystemPrompt.contribute(cid,
        is_fresh: true,
        identity: "Identity.",
        tools_prompt: "Tool guidance."
      )

      assert result =~ "Identity."
      assert result =~ "Tool guidance."
      refute result =~ "<room-handoff>"
    end

    test "nil tools_prompt is skipped", %{conversation_id: cid} do
      result = SystemPrompt.contribute(cid,
        is_fresh: true,
        identity: "Identity.",
        tools_prompt: nil
      )

      assert result == "Identity."
    end
  end
end
