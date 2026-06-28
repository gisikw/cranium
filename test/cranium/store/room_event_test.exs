defmodule Cranium.Store.RoomEventTest do
  use ExUnit.Case, async: true

  alias Cranium.Store
  alias Cranium.Store.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Store GenServer is already running in the test supervision tree
    :ok
  end

  describe "emit_room_event/4" do
    test "assigns seq starting at 1 for a new room" do
      {:ok, event} = Store.emit_room_event("test-room", "message.created", %{"text" => "hello"})

      assert event.room_id == "test-room"
      assert event.seq == 1
      assert event.type == "message.created"
      assert event.payload == %{"text" => "hello"}
      assert event.correlation_id == nil
      assert %DateTime{} = event.occurred_at
    end

    test "assigns monotonically increasing seq per room" do
      {:ok, e1} = Store.emit_room_event("seq-room", "turn.started", %{})
      {:ok, e2} = Store.emit_room_event("seq-room", "message.created", %{})
      {:ok, e3} = Store.emit_room_event("seq-room", "turn.completed", %{})

      assert e1.seq == 1
      assert e2.seq == 2
      assert e3.seq == 3
    end

    test "seq is independent per room" do
      {:ok, a1} = Store.emit_room_event("room-a", "message.created", %{})
      {:ok, b1} = Store.emit_room_event("room-b", "message.created", %{})
      {:ok, a2} = Store.emit_room_event("room-a", "turn.completed", %{})

      assert a1.seq == 1
      assert b1.seq == 1
      assert a2.seq == 2
    end

    test "preserves correlation_id" do
      {:ok, event} =
        Store.emit_room_event("corr-room", "message.created", %{}, "cmd_abc123")

      assert event.correlation_id == "cmd_abc123"
    end
  end

  describe "list_room_events/3" do
    test "returns events after given seq in ascending order" do
      {:ok, _} = Store.emit_room_event("list-room", "turn.started", %{"a" => 1})
      {:ok, _} = Store.emit_room_event("list-room", "message.created", %{"b" => 2})
      {:ok, _} = Store.emit_room_event("list-room", "turn.completed", %{"c" => 3})

      {:ok, events} = Store.list_room_events("list-room", 1)

      assert length(events) == 2
      assert Enum.at(events, 0).seq == 2
      assert Enum.at(events, 1).seq == 3
    end

    test "returns empty list when no events after cursor" do
      {:ok, _} = Store.emit_room_event("empty-room", "message.created", %{})

      {:ok, events} = Store.list_room_events("empty-room", 1)
      assert events == []
    end

    test "returns all events when since_seq is 0" do
      {:ok, _} = Store.emit_room_event("all-room", "turn.started", %{})
      {:ok, _} = Store.emit_room_event("all-room", "message.created", %{})

      {:ok, events} = Store.list_room_events("all-room", 0)
      assert length(events) == 2
    end

    test "respects limit option" do
      for i <- 1..5 do
        Store.emit_room_event("limit-room", "message.created", %{"i" => i})
      end

      {:ok, events} = Store.list_room_events("limit-room", 0, limit: 3)
      assert length(events) == 3
      assert Enum.at(events, 0).seq == 1
      assert Enum.at(events, 2).seq == 3
    end

    test "does not return events from other rooms" do
      {:ok, _} = Store.emit_room_event("iso-a", "message.created", %{})
      {:ok, _} = Store.emit_room_event("iso-b", "message.created", %{})

      {:ok, events} = Store.list_room_events("iso-a", 0)
      assert length(events) == 1
      assert Enum.at(events, 0).room_id == "iso-a"
    end
  end

  describe "latest_room_event_seq/1" do
    test "returns 0 for room with no events" do
      {:ok, seq} = Store.latest_room_event_seq("no-events-room")
      assert seq == 0
    end

    test "returns latest seq for room" do
      Store.emit_room_event("latest-room", "turn.started", %{})
      Store.emit_room_event("latest-room", "message.created", %{})
      Store.emit_room_event("latest-room", "turn.completed", %{})

      {:ok, seq} = Store.latest_room_event_seq("latest-room")
      assert seq == 3
    end
  end

  describe "purge_room_events_before/1" do
    test "deletes events older than given timestamp" do
      {:ok, e1} = Store.emit_room_event("purge-room", "old.event", %{})
      {:ok, _e2} = Store.emit_room_event("purge-room", "new.event", %{})

      # Purge everything before the second event
      cutoff = DateTime.add(e1.occurred_at, 1, :microsecond)
      {:ok, count} = Store.purge_room_events_before(cutoff)

      assert count == 1

      {:ok, remaining} = Store.list_room_events("purge-room", 0)
      assert length(remaining) == 1
      assert Enum.at(remaining, 0).type == "new.event"
    end
  end
end
