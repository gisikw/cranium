defmodule Cranium.Backend.SSETest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.SSE

  describe "parse/2" do
    test "parses a complete event" do
      state = SSE.new()
      chunk = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"

      {events, _state} = SSE.parse(state, chunk)

      assert [%{event: "message_start", data: "{\"type\":\"message_start\"}"}] = events
    end

    test "handles partial chunks" do
      state = SSE.new()

      {events, state} = SSE.parse(state, "event: content_block")
      assert events == []

      {events, state} = SSE.parse(state, "_delta\ndata: {\"text\":\"hi\"}")
      assert events == []

      {events, _state} = SSE.parse(state, "\n\n")
      assert [%{event: "content_block_delta", data: "{\"text\":\"hi\"}"}] = events
    end

    test "parses multiple events in one chunk" do
      state = SSE.new()

      chunk =
        "event: ping\ndata: {}\n\nevent: message_start\ndata: {\"type\":\"message_start\"}\n\n"

      {events, _state} = SSE.parse(state, chunk)
      assert length(events) == 2
      assert [%{event: "ping"}, %{event: "message_start"}] = events
    end

    test "handles event with no event type" do
      state = SSE.new()
      chunk = "data: {\"type\":\"ping\"}\n\n"

      {events, _state} = SSE.parse(state, chunk)
      assert [%{event: nil, data: "{\"type\":\"ping\"}"}] = events
    end

    test "skips empty blocks" do
      state = SSE.new()
      chunk = "\n\nevent: test\ndata: hi\n\n"

      {events, _state} = SSE.parse(state, chunk)
      # Empty block produces nil, gets rejected
      assert [%{event: "test", data: "hi"}] = events
    end

    test "preserves buffer across multiple parses" do
      state = SSE.new()

      {events, state} = SSE.parse(state, "event: a\ndata: 1\n\nevent: b\n")
      assert [%{event: "a", data: "1"}] = events

      {events, _state} = SSE.parse(state, "data: 2\n\n")
      assert [%{event: "b", data: "2"}] = events
    end
  end
end
