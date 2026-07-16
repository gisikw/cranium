defmodule Cranium.Store.RoomReadMarkerTest do
  # Not async: the Store GenServer reaches the sandbox through shared
  # mode, and two concurrently-running shared-mode modules clobber each
  # other's ownership (RoomEventTest already occupies the async slot).
  use CraniumTest.DataCase, async: false

  alias Cranium.Store

  describe "mark_room_read/2" do
    test "creates a marker at seq 0 for a room with no events" do
      {:ok, marker} = Store.mark_room_read("marker-empty-room")

      assert marker.room_id == "marker-empty-room"
      assert marker.last_read_seq == 0
      assert %DateTime{} = marker.last_read_at
    end

    test "advances to the latest event seq when seq is omitted" do
      {:ok, _} = Store.emit_room_event("marker-latest-room", "message.created", %{})
      {:ok, _} = Store.emit_room_event("marker-latest-room", "turn.completed", %{})

      {:ok, marker} = Store.mark_room_read("marker-latest-room")

      assert marker.last_read_seq == 2
    end

    test "sets an explicit seq and anchors last_read_at to that event" do
      {:ok, e1} = Store.emit_room_event("marker-explicit-room", "message.created", %{})
      {:ok, _e2} = Store.emit_room_event("marker-explicit-room", "message.created", %{})

      {:ok, marker} = Store.mark_room_read("marker-explicit-room", 1)

      assert marker.last_read_seq == 1
      assert DateTime.compare(marker.last_read_at, e1.occurred_at) == :eq
    end

    test "clamps seq beyond the latest known event" do
      {:ok, _} = Store.emit_room_event("marker-clamp-room", "message.created", %{})

      {:ok, marker} = Store.mark_room_read("marker-clamp-room", 999)

      assert marker.last_read_seq == 1
    end

    test "never moves the marker backwards" do
      {:ok, _} = Store.emit_room_event("marker-mono-room", "message.created", %{})
      {:ok, _} = Store.emit_room_event("marker-mono-room", "message.created", %{})
      {:ok, _} = Store.emit_room_event("marker-mono-room", "message.created", %{})

      {:ok, first} = Store.mark_room_read("marker-mono-room", 3)
      {:ok, second} = Store.mark_room_read("marker-mono-room", 1)

      assert first.last_read_seq == 3
      assert second.last_read_seq == 3
      assert DateTime.compare(second.last_read_at, first.last_read_at) == :eq
    end

    test "is idempotent for repeated marks at the same seq" do
      {:ok, _} = Store.emit_room_event("marker-idem-room", "message.created", %{})

      {:ok, first} = Store.mark_room_read("marker-idem-room", 1)
      {:ok, second} = Store.mark_room_read("marker-idem-room", 1)

      assert first.last_read_seq == 1
      assert second.last_read_seq == 1
      assert DateTime.compare(second.last_read_at, first.last_read_at) == :eq
    end

    test "markers are independent per room" do
      {:ok, _} = Store.emit_room_event("marker-room-a", "message.created", %{})

      {:ok, a} = Store.mark_room_read("marker-room-a")
      {:ok, b} = Store.mark_room_read("marker-room-b")

      assert a.last_read_seq == 1
      assert b.last_read_seq == 0
    end
  end

  describe "get_room_read_marker/1" do
    test "returns nil for a room never marked read" do
      assert {:ok, nil} = Store.get_room_read_marker("marker-unmarked-room")
    end

    test "returns the persisted marker" do
      {:ok, _} = Store.emit_room_event("marker-get-room", "message.created", %{})
      {:ok, written} = Store.mark_room_read("marker-get-room")

      {:ok, read} = Store.get_room_read_marker("marker-get-room")

      assert read.room_id == "marker-get-room"
      assert read.last_read_seq == written.last_read_seq
      assert DateTime.compare(read.last_read_at, written.last_read_at) == :eq
    end
  end
end
