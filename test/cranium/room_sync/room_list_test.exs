defmodule Cranium.RoomSync.RoomListTest do
  @moduledoc """
  Tests for room list enrichment with latest_message_preview,
  latest_message_at, and has_active_turn.
  """

  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.RoomSync.RoomList

  setup do
    room_id = "roomlist-test-#{Ecto.UUID.generate()}"
    {:ok, _} = Cranium.Store.get_or_create_epoch(room_id)
    {:ok, room_id: room_id}
  end

  describe "enrich/1" do
    test "adds sync fields to landscape rooms", %{room_id: room_id} do
      rooms = [%{id: room_id, name: room_id, description: nil, last_activity_at: nil}]

      [enriched] = RoomList.enrich(rooms)

      assert enriched.id == room_id
      assert enriched.name == room_id
      assert enriched.has_active_turn == false
      assert enriched.unread == false
      # No messages yet
      assert enriched.latest_message_preview == nil
      assert enriched.latest_message_at == nil
    end

    test "includes latest message preview when messages exist", %{room_id: room_id} do
      # Add a message through Store
      {:ok, epoch_ctx} = Cranium.Store.get_or_create_epoch(room_id)

      Cranium.Store.append_message(room_id, epoch_ctx.epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "Hello, world!"}]
      })

      Cranium.Store.append_message(room_id, epoch_ctx.epoch_id, %{
        role: "assistant",
        content: [%{"type" => "text", "text" => "Hi there, how can I help?"}]
      })

      rooms = [%{id: room_id, name: room_id, description: nil, last_activity_at: nil}]
      [enriched] = RoomList.enrich(rooms)

      # Should show the latest (assistant) message
      assert enriched.latest_message_preview == "Hi there, how can I help?"
      assert enriched.latest_message_at != nil
    end

    test "truncates long message previews", %{room_id: room_id} do
      {:ok, epoch_ctx} = Cranium.Store.get_or_create_epoch(room_id)

      long_text = String.duplicate("a", 200)

      Cranium.Store.append_message(room_id, epoch_ctx.epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => long_text}]
      })

      rooms = [%{id: room_id, name: room_id, description: nil, last_activity_at: nil}]
      [enriched] = RoomList.enrich(rooms)

      assert String.length(enriched.latest_message_preview) <= 121  # 120 + "…"
      assert String.ends_with?(enriched.latest_message_preview, "…")
    end

    test "excludes orientation messages from previews", %{room_id: room_id} do
      {:ok, epoch_ctx} = Cranium.Store.get_or_create_epoch(room_id)

      Cranium.Store.append_message(room_id, epoch_ctx.epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "Real message"}]
      })

      Cranium.Store.append_message(room_id, epoch_ctx.epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "Orientation content"}],
        origin: "orientation"
      })

      rooms = [%{id: room_id, name: room_id, description: nil, last_activity_at: nil}]
      [enriched] = RoomList.enrich(rooms)

      assert enriched.latest_message_preview == "Real message"
    end

    test "handles multiple rooms in batch", %{room_id: room_id} do
      room_id2 = "roomlist-test-#{Ecto.UUID.generate()}"
      {:ok, _} = Cranium.Store.get_or_create_epoch(room_id2)

      {:ok, epoch1} = Cranium.Store.get_or_create_epoch(room_id)
      {:ok, epoch2} = Cranium.Store.get_or_create_epoch(room_id2)

      Cranium.Store.append_message(room_id, epoch1.epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "Room 1 message"}]
      })

      Cranium.Store.append_message(room_id2, epoch2.epoch_id, %{
        role: "assistant",
        content: [%{"type" => "text", "text" => "Room 2 message"}]
      })

      rooms = [
        %{id: room_id, name: room_id, description: nil, last_activity_at: nil},
        %{id: room_id2, name: room_id2, description: nil, last_activity_at: nil}
      ]

      enriched = RoomList.enrich(rooms)
      assert length(enriched) == 2

      by_id = Map.new(enriched, & {&1.id, &1})
      assert by_id[room_id].latest_message_preview == "Room 1 message"
      assert by_id[room_id2].latest_message_preview == "Room 2 message"
    end

    test "returns empty list for empty input" do
      assert RoomList.enrich([]) == []
    end
  end
end
