defmodule Cranium.Ingress.CommandDetectorTest do
  use ExUnit.Case, async: true

  alias Cranium.Ingress.CommandDetector

  @base_event %{
    event_id: "evt-1",
    room_id: "test-room",
    sender: "@user:example.com",
    timestamp: ~U[2026-03-05 10:00:00Z]
  }

  describe "process/2" do
    test "detects !clear command" do
      event = Map.put(@base_event, :body, "!clear")
      assert {:command, :clear, %{room_id: "test-room"}} = CommandDetector.process(event, %{})
    end

    test "detects !cancel command" do
      event = Map.put(@base_event, :body, "!cancel")
      assert {:command, :cancel, %{room_id: "test-room"}} = CommandDetector.process(event, %{})
    end

    test "detects !usage command" do
      event = Map.put(@base_event, :body, "!usage")
      assert {:command, :usage, %{room_id: "test-room"}} = CommandDetector.process(event, %{})
    end

    test "detects !new with room name" do
      event = Map.put(@base_event, :body, "!new my-project")

      assert {:command, :new_room, %{room_id: "test-room", name: "my-project"}} =
               CommandDetector.process(event, %{})
    end

    test "passes through regular messages" do
      event = Map.put(@base_event, :body, "Hello, how are you?")
      assert {:ok, normalized} = CommandDetector.process(event, %{})
      assert normalized.text == "Hello, how are you?"
      assert normalized.room_id == "test-room"
    end

    test "normalizes event fields" do
      event = Map.merge(@base_event, %{body: "test message", attachments: []})
      assert {:ok, normalized} = CommandDetector.process(event, %{})
      assert normalized.text == "test message"
      assert normalized.attachments == []
      assert normalized.event_id == "evt-1"
      assert normalized.sender == "@user:example.com"
    end
  end
end
