defmodule Cranium.RoomSync.TranscriptMessageTest do
  use ExUnit.Case, async: true

  alias Cranium.RoomSync.TranscriptMessage
  alias Cranium.Store.Message

  defp make_message(attrs) do
    base = %Message{
      id: Ecto.UUID.generate(),
      conversation_id: "test-room",
      epoch_id: Ecto.UUID.generate(),
      role: "assistant",
      content: [%{"type" => "text", "text" => "hello"}],
      origin: nil,
      usage: nil,
      parent_id: nil,
      provenance: nil,
      inserted_at: DateTime.utc_now()
    }

    struct!(base, attrs)
  end

  describe "project/2" do
    test "projects a simple text message" do
      msg =
        make_message(role: "assistant", content: [%{"type" => "text", "text" => "hello world"}])

      result = TranscriptMessage.project(msg)

      assert result.id == msg.id
      assert result.room_id == "test-room"
      assert result.role == "assistant"
      assert result.text == "hello world"
      assert length(result.parts) == 1

      [part] = result.parts
      assert part.type == "text"
      assert part.text == "hello world"
      assert part.id == "#{msg.id}:0"
    end

    test "projects multiple text blocks" do
      msg =
        make_message(
          content: [
            %{"type" => "text", "text" => "first "},
            %{"type" => "text", "text" => "second"}
          ]
        )

      result = TranscriptMessage.project(msg)
      assert result.text == "first second"
      assert length(result.parts) == 2
    end

    test "projects tool_use blocks as tool_call parts" do
      tool_use_id = Ecto.UUID.generate()

      msg =
        make_message(
          content: [
            %{"type" => "text", "text" => "Let me check that."},
            %{
              "type" => "tool_use",
              "id" => tool_use_id,
              "name" => "read",
              "input" => %{"path" => "foo.txt"}
            }
          ]
        )

      result = TranscriptMessage.project(msg)
      assert length(result.parts) == 2

      [_text_part, tool_part] = result.parts
      assert tool_part.type == "tool_call"
      assert tool_part.tool == "read"
      assert tool_part.input == %{"path" => "foo.txt"}
      assert tool_part.status == "complete"
    end

    test "tool_call status reflects error from tool_results" do
      tool_use_id = Ecto.UUID.generate()

      msg =
        make_message(
          content: [
            %{"type" => "tool_use", "id" => tool_use_id, "name" => "bash", "input" => %{}}
          ]
        )

      tool_results = %{
        tool_use_id => %{"is_error" => true, "content" => "command not found"}
      }

      result = TranscriptMessage.project(msg, tool_results: tool_results)
      [part] = result.parts
      assert part.status == "error"
      assert part.summary == "command not found"
    end

    test "projects tool_result blocks" do
      tool_use_id = Ecto.UUID.generate()

      msg =
        make_message(
          role: "user",
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => tool_use_id,
              "content" => "file contents here",
              "is_error" => false
            }
          ]
        )

      result = TranscriptMessage.project(msg)
      [part] = result.parts
      assert part.type == "tool_result"
      assert part.tool_use_id == tool_use_id
      assert part.content == "file contents here"
      assert part.is_error == false
    end

    test "projects image blocks" do
      msg =
        make_message(
          content: [
            %{
              "type" => "image",
              "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "abc123"}
            }
          ]
        )

      result = TranscriptMessage.project(msg)
      [part] = result.parts
      assert part.type == "image"
      assert part.media_type == "image/png"
      assert part.source == "base64"
    end

    test "part IDs are deterministic" do
      msg =
        make_message(
          content: [
            %{"type" => "text", "text" => "a"},
            %{"type" => "text", "text" => "b"},
            %{"type" => "text", "text" => "c"}
          ]
        )

      result1 = TranscriptMessage.project(msg)
      result2 = TranscriptMessage.project(msg)

      assert Enum.map(result1.parts, & &1.id) == Enum.map(result2.parts, & &1.id)

      assert Enum.map(result1.parts, & &1.id) == [
               "#{msg.id}:0",
               "#{msg.id}:1",
               "#{msg.id}:2"
             ]
    end

    test "includes provenance and usage when present" do
      msg =
        make_message(
          provenance: %{"model" => "claude-sonnet"},
          usage: %{"input_tokens" => 100, "output_tokens" => 50}
        )

      result = TranscriptMessage.project(msg)
      assert result.provenance == %{"model" => "claude-sonnet"}
      assert result.usage == %{"input_tokens" => 100, "output_tokens" => 50}
    end

    test "omits provenance and usage when nil" do
      msg = make_message(provenance: nil, usage: nil)
      result = TranscriptMessage.project(msg)
      refute Map.has_key?(result, :provenance)
      refute Map.has_key?(result, :usage)
    end

    test "handles plain string content" do
      msg = make_message(content: "just a string")
      result = TranscriptMessage.project(msg)
      assert result.text == "just a string"
      assert [%{type: "text", text: "just a string"}] = result.parts
    end

    test "handles nil content" do
      msg = make_message(content: nil)
      result = TranscriptMessage.project(msg)
      assert result.text == ""
      assert result.parts == []
    end
  end

  describe "project_many/1" do
    test "excludes orientation-origin messages" do
      messages = [
        make_message(origin: "orientation", role: "assistant"),
        make_message(origin: nil, role: "user", content: [%{"type" => "text", "text" => "hi"}]),
        make_message(origin: nil, role: "assistant")
      ]

      results = TranscriptMessage.project_many(messages)
      assert length(results) == 2
      refute Enum.any?(results, &(&1.origin == "orientation"))
    end

    test "excludes tool_result-only user messages" do
      tool_use_id = Ecto.UUID.generate()

      messages = [
        make_message(
          role: "assistant",
          content: [
            %{"type" => "tool_use", "id" => tool_use_id, "name" => "read", "input" => %{}}
          ]
        ),
        make_message(
          role: "user",
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => tool_use_id,
              "content" => "result",
              "is_error" => false
            }
          ]
        ),
        make_message(
          role: "assistant",
          content: [
            %{"type" => "text", "text" => "Got it."}
          ]
        )
      ]

      results = TranscriptMessage.project_many(messages)
      # The tool_result-only user message should be excluded
      assert length(results) == 2
      roles = Enum.map(results, & &1.role)
      assert roles == ["assistant", "assistant"]
    end

    test "resolves tool_call status from subsequent tool_result messages" do
      tool_use_id = Ecto.UUID.generate()

      messages = [
        make_message(
          role: "assistant",
          content: [
            %{
              "type" => "tool_use",
              "id" => tool_use_id,
              "name" => "bash",
              "input" => %{"command" => "ls"}
            }
          ]
        ),
        make_message(
          role: "user",
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => tool_use_id,
              "content" => "file1\nfile2",
              "is_error" => false
            }
          ]
        )
      ]

      results = TranscriptMessage.project_many(messages)
      # Only the assistant message remains (tool_result-only excluded)
      assert length(results) == 1
      [assistant] = results
      [tool_part] = assistant.parts
      assert tool_part.status == "complete"
    end

    test "keeps user messages that mix text and tool_results" do
      messages = [
        make_message(
          role: "user",
          content: [
            %{"type" => "text", "text" => "Here's context"},
            %{
              "type" => "tool_result",
              "tool_use_id" => Ecto.UUID.generate(),
              "content" => "data",
              "is_error" => false
            }
          ]
        )
      ]

      results = TranscriptMessage.project_many(messages)
      assert length(results) == 1
    end
  end
end
