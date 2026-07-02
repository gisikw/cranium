defmodule Cranium.RoomSync.SnapshotTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.RoomSync.Snapshot

  setup do
    room_id = "snapshot-test-#{Ecto.UUID.generate()}"
    {:ok, room_id: room_id}
  end

  describe "build/1" do
    test "returns snapshot for a new room with no messages", %{room_id: room_id} do
      assert {:ok, snapshot} = Snapshot.build(room_id)

      # Room metadata
      assert snapshot.room.id == room_id
      assert snapshot.room.title == room_id

      # State
      assert snapshot.state.saturation == 0.0
      assert snapshot.state.turn_count == 0
      assert snapshot.state.handoff_generating == false
      assert snapshot.state.active_turn == nil
      assert is_binary(snapshot.state.epoch_id)

      # Transcript
      assert snapshot.recent_transcript == []
      assert snapshot.has_more == false

      # Cursor
      assert snapshot.cursor.room_id == room_id
      assert is_integer(snapshot.cursor.seq)
    end

    test "serves saturation as a 0..1 fraction matching turn.completed scale", %{
      room_id: room_id
    } do
      {:ok, ctx} = Cranium.Store.get_or_create_epoch(room_id)
      :ok = Cranium.Store.update_epoch(ctx.epoch_id, %{saturation: 0.42})

      assert {:ok, snapshot} = Snapshot.build(room_id)
      assert snapshot.state.saturation == 0.42
    end

    test "returns snapshot with messages after submitting content", %{room_id: room_id} do
      # Create epoch and append a message
      {:ok, ctx} = Cranium.Store.get_or_create_epoch(room_id)
      epoch_id = ctx.epoch_id

      Cranium.Store.append_message(room_id, epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "Hello"}],
        origin: "test"
      })

      Cranium.Store.append_message(room_id, epoch_id, %{
        role: "assistant",
        content: [%{"type" => "text", "text" => "Hi there!"}],
        origin: nil
      })

      assert {:ok, snapshot} = Snapshot.build(room_id)

      assert length(snapshot.recent_transcript) == 2

      [user_msg, assistant_msg] = snapshot.recent_transcript
      assert user_msg.role == "user"
      assert user_msg.text == "Hello"
      assert assistant_msg.role == "assistant"
      assert assistant_msg.text == "Hi there!"

      # Each message has parts
      assert length(user_msg.parts) == 1
      assert hd(user_msg.parts).type == "text"
    end

    test "excludes orientation messages from transcript", %{room_id: room_id} do
      {:ok, ctx} = Cranium.Store.get_or_create_epoch(room_id)
      epoch_id = ctx.epoch_id

      Cranium.Store.append_message(room_id, epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "orientation stuff"}],
        origin: "orientation"
      })

      Cranium.Store.append_message(room_id, epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "real message"}],
        origin: "test"
      })

      assert {:ok, snapshot} = Snapshot.build(room_id)

      # Only the non-orientation message should appear
      assert length(snapshot.recent_transcript) == 1
      assert hd(snapshot.recent_transcript).text == "real message"
    end

    test "cursor seq is non-negative", %{room_id: room_id} do
      assert {:ok, snapshot} = Snapshot.build(room_id)
      assert snapshot.cursor.seq >= 0
    end
  end
end
