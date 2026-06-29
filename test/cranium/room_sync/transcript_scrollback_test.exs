defmodule Cranium.RoomSync.TranscriptScrollbackTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  setup do
    room_id = "scrollback-test-#{Ecto.UUID.generate()}"

    # Create epoch and seed messages
    {:ok, ctx} = Cranium.Store.get_or_create_epoch(room_id)
    epoch_id = ctx.epoch_id

    # Insert 5 messages with staggered timestamps
    message_ids =
      for i <- 1..5 do
        Cranium.Store.append_message(room_id, epoch_id, %{
          role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
          content: [%{"type" => "text", "text" => "Message #{i}"}],
          origin: nil
        })

        # Small sleep to ensure distinct inserted_at values
        Process.sleep(5)

        # Fetch the latest message to get its ID
        {:ok, %{messages: msgs}} =
          Cranium.Store.recent_message_structs(room_id, limit: i)

        List.last(msgs).id
      end

    {:ok, room_id: room_id, epoch_id: epoch_id, message_ids: message_ids}
  end

  describe "GET /v1/rooms/:room_id/transcript" do
    test "returns most recent messages with no cursor", %{room_id: room_id} do
      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?limit=3")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert length(body["messages"]) == 3
      assert body["has_more"] == true
    end

    test "returns all messages when limit exceeds count", %{room_id: room_id} do
      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?limit=100")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert length(body["messages"]) == 5
      assert body["has_more"] == false
    end

    test "paginates backward with before cursor", %{
      room_id: room_id,
      message_ids: message_ids
    } do
      # Get the 3rd message ID as cursor
      cursor_id = Enum.at(message_ids, 2)

      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?before=#{cursor_id}&limit=10")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      # Should get messages 1 and 2 (before message 3)
      assert length(body["messages"]) == 2
      assert body["has_more"] == false
    end

    test "paginates forward with after cursor", %{
      room_id: room_id,
      message_ids: message_ids
    } do
      # Get the 3rd message ID as cursor
      cursor_id = Enum.at(message_ids, 2)

      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?after=#{cursor_id}&limit=10")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      # Should get messages 4 and 5 (after message 3)
      assert length(body["messages"]) == 2
      assert body["has_more"] == false
    end

    test "returns TranscriptMessage shape with parts", %{room_id: room_id} do
      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?limit=1")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      [msg] = body["messages"]
      assert is_binary(msg["id"])
      assert msg["room_id"] == room_id
      assert msg["role"] in ["user", "assistant"]
      assert is_list(msg["parts"])
      assert is_binary(msg["text"])

      [part] = msg["parts"]
      assert part["type"] == "text"
      assert is_binary(part["id"])
    end

    test "excludes orientation messages", %{room_id: room_id, epoch_id: epoch_id} do
      # Add an orientation message
      Cranium.Store.append_message(room_id, epoch_id, %{
        role: "user",
        content: [%{"type" => "text", "text" => "orientation only"}],
        origin: "orientation"
      })

      conn =
        Plug.Test.conn(:get, "/v1/rooms/#{room_id}/transcript?limit=100")
        |> Cranium.Transport.HTTP.call(Cranium.Transport.HTTP.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      # Still only 5 — orientation message excluded
      assert length(body["messages"]) == 5

      texts = Enum.map(body["messages"], & &1["text"])
      refute "orientation only" in texts
    end
  end
end
