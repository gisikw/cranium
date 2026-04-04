defmodule Cranium.Effects.PassReactorTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.Effects.PassReactor

  defp flush_effects, do: GenServer.call(PassReactor, :flush)

  describe "pass_complete (success)" do
    test "persists assistant message and updates epoch state" do
      conversation_id = "test-effects-#{System.unique_integer([:positive])}"

      # Create epoch
      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Simulate pass_complete from Harness
      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :complete,
        epoch_id: ctx.epoch_id,
        output: "hello world",
        saturation: 0.5,
        turn_count: 1,
        cc_session_id: "cc-123",
        ephemeral: false
      }})

      flush_effects()

      # Verify assistant message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      assert Enum.any?(messages, fn m -> m.role == :assistant and m.content == "hello world" end)

      # Verify epoch state was updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.saturation == 0.5
      assert epoch.turn_count == 1
      assert epoch.cc_session_id == "cc-123"
      assert epoch.interrupted_context == nil
      assert epoch.status == "active"
    end

    test "skips Store mutations for ephemeral passes" do
      conversation_id = "test-effects-eph-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :complete,
        epoch_id: ctx.epoch_id,
        output: "ephemeral output",
        saturation: 0.3,
        turn_count: 1,
        cc_session_id: "cc-456",
        ephemeral: true
      }})

      flush_effects()

      # Verify no message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      # Verify epoch state was NOT updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.turn_count == 0
    end

    test "skips message persistence for empty output" do
      conversation_id = "test-effects-empty-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :complete,
        epoch_id: ctx.epoch_id,
        output: "",
        saturation: 0.1,
        turn_count: 1,
        cc_session_id: nil,
        ephemeral: false
      }})

      flush_effects()

      # No assistant message (empty output)
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      # But epoch state still updated
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.turn_count == 1
    end
  end

  describe "pass_complete (cancelled)" do
    test "persists partial output and stores interrupted context" do
      conversation_id = "test-effects-cancel-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :cancelled,
        epoch_id: ctx.epoch_id,
        output: "partial output here",
        cc_session_id: "cc-789",
        ephemeral: false
      }})

      flush_effects()

      # Verify partial message was persisted
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      assert Enum.any?(messages, fn m -> m.role == :assistant and m.content == "partial output here" end)

      # Verify interrupted_context was stored
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == "partial output here"
      assert epoch.cc_session_id == "cc-789"
    end

    test "truncates long interrupted context to 2000 chars" do
      conversation_id = "test-effects-trunc-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)
      long_output = String.duplicate("x", 3000)

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :cancelled,
        epoch_id: ctx.epoch_id,
        output: long_output,
        cc_session_id: nil,
        ephemeral: false
      }})

      flush_effects()

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert String.length(epoch.interrupted_context) < 3000
      assert String.ends_with?(epoch.interrupted_context, "[...output truncated...]")
    end

    test "handles empty partial output on cancel" do
      conversation_id = "test-effects-cancel-empty-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :cancelled,
        epoch_id: ctx.epoch_id,
        output: "",
        cc_session_id: nil,
        ephemeral: false
      }})

      flush_effects()

      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      refute Enum.any?(messages, fn m -> m.role == :assistant end)

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == nil
    end
  end

  describe "pass_complete (error)" do
    test "resets epoch status to active" do
      conversation_id = "test-effects-error-#{System.unique_integer([:positive])}"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Set status to inferring first
      Cranium.Store.update_epoch(ctx.epoch_id, %{status: "inferring"})

      send(PassReactor, {:pass_complete, conversation_id, "stream-1", %{
        reason: :error,
        epoch_id: ctx.epoch_id,
        ephemeral: false
      }})

      flush_effects()

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.status == "active"
    end
  end

  describe "pass_done signaling" do
    test "signals pass_done to TurnAssembler after successful pass" do
      conversation_id = "test-effects-passdone-#{System.unique_integer([:positive])}"
      stream_id = "stream-pd-1"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      # Register test process as TurnAssembler
      Registry.register(
        Cranium.Inference.ConversationRegistry,
        {conversation_id, :turn_assembler},
        []
      )

      send(PassReactor, {:pass_complete, conversation_id, stream_id, %{
        reason: :complete,
        epoch_id: ctx.epoch_id,
        output: "done",
        saturation: 0.1,
        turn_count: 1,
        cc_session_id: nil,
        ephemeral: false
      }})

      assert_receive {:pass_done, ^stream_id}, 1000
    end

    test "signals pass_done even for ephemeral passes" do
      conversation_id = "test-effects-passdone-eph-#{System.unique_integer([:positive])}"
      stream_id = "stream-pd-2"

      {:ok, ctx} = Cranium.Store.get_or_create_epoch(conversation_id)

      Registry.register(
        Cranium.Inference.ConversationRegistry,
        {conversation_id, :turn_assembler},
        []
      )

      send(PassReactor, {:pass_complete, conversation_id, stream_id, %{
        reason: :complete,
        epoch_id: ctx.epoch_id,
        output: "",
        saturation: 0.0,
        turn_count: 1,
        cc_session_id: nil,
        ephemeral: true
      }})

      assert_receive {:pass_done, ^stream_id}, 1000
    end
  end
end
