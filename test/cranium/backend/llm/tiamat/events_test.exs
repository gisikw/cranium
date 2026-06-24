defmodule Cranium.Backend.LLM.Tiamat.EventsTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.Tiamat.Events

  test "decodes native turn_response envelopes from payload.response" do
    response = %{
      "schema" => "tiamat.turn.response.v1",
      "status" => "completed",
      "transcript_delta" => []
    }

    event = %{
      event: nil,
      data:
        Jason.encode!(%{
          "schema" => "tiamat.turn.event.v1",
          "event_id" => "evt_1",
          "request_id" => "req_1",
          "sequence" => 12,
          "type" => "turn_response",
          "payload" => %{"response" => response}
        })
    }

    assert {:ok, envelope} = Events.decode_sse(event)
    assert {:ok, ^response} = Events.turn_response(envelope)
  end

  test "wraps legacy turn_response SSE data as a native envelope" do
    response = %{"status" => "completed", "transcript_delta" => []}

    assert {:ok, envelope} =
             Events.decode_sse(%{event: "turn_response", data: Jason.encode!(response)})

    assert Events.type(envelope) == "turn_response"
    assert {:ok, ^response} = Events.turn_response(envelope)
  end

  test "extracts generic text content deltas" do
    event = %{
      "schema" => "tiamat.turn.event.v1",
      "type" => "content_part_delta",
      "payload" => %{
        "content_type" => "text",
        "delta" => %{"text" => "hello"}
      }
    }

    assert Events.text_delta(event) == "hello"
  end

  test "extracts completed text content" do
    event = %{
      "schema" => "tiamat.turn.event.v1",
      "type" => "content_part_completed",
      "payload" => %{
        "part_id" => "part_1",
        "content_type" => "text",
        "completion_status" => "completed",
        "content" => %{"type" => "text", "text" => "full text"}
      }
    }

    assert Events.part_id(event) == "part_1"
    assert Events.completed_text(event) == "full text"
  end

  test "projects completed tool_use content into Cranium tool call shape" do
    event = %{
      "schema" => "tiamat.turn.event.v1",
      "type" => "content_part_completed",
      "payload" => %{
        "content_type" => "tool_use",
        "completion_status" => "completed",
        "content" => %{
          "type" => "tool_use",
          "tool_use_id" => "toolu_1",
          "tool_name" => "bash",
          "tool_input" => %{"command" => "printf hi"}
        }
      }
    }

    assert [block] = Events.completed_content(event)

    assert Events.tool_calls([block]) == [
             %{id: "toolu_1", name: "bash", input: %{"command" => "printf hi"}}
           ]
  end
end
