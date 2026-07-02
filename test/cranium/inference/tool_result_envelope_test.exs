defmodule Cranium.Inference.ToolResultEnvelopeTest do
  use ExUnit.Case, async: true

  alias Cranium.Inference.ToolResultEnvelope

  defp envelope_string(blocks) do
    Jason.encode!(%{"type" => "content", "content" => blocks})
  end

  defp image_block(data \\ "png-bytes") do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => "image/png",
        "data" => Base.encode64(data)
      }
    }
  end

  describe "parse/1" do
    test "accepts an envelope with text and image blocks" do
      blocks = [%{"type" => "text", "text" => "screenshot.png: image/png"}, image_block()]

      assert {:ok, ^blocks} = ToolResultEnvelope.parse(envelope_string(blocks))
    end

    test "accepts an envelope with leading whitespace" do
      assert {:ok, []} = ToolResultEnvelope.parse("  \n" <> envelope_string([]))
    end

    test "rejects legacy plain text" do
      assert :error = ToolResultEnvelope.parse("just some tool output")
    end

    test "rejects legacy JSON objects with a string content field" do
      legacy = Jason.encode!(%{"content" => "file contents", "path" => "/tmp/a.txt"})
      assert :error = ToolResultEnvelope.parse(legacy)
    end

    test "rejects objects whose type is content but content is not an array" do
      assert :error = ToolResultEnvelope.parse(~s({"type": "content", "content": "text"}))
    end

    test "rejects objects whose type is not content" do
      assert :error = ToolResultEnvelope.parse(~s({"type": "text", "content": []}))
    end

    test "rejects malformed JSON" do
      assert :error = ToolResultEnvelope.parse(~s({"type": "content", "content": [))
    end

    test "rejects non-binary values" do
      assert :error = ToolResultEnvelope.parse(%{"type" => "content", "content" => []})
      assert :error = ToolResultEnvelope.parse(nil)
    end
  end

  describe "display_text/1" do
    test "joins text blocks and replaces images with placeholders" do
      blocks = [
        %{"type" => "text", "text" => "screenshot.png: image/png, 123 bytes"},
        image_block()
      ]

      assert ToolResultEnvelope.display_text(blocks) ==
               "screenshot.png: image/png, 123 bytes\n[image omitted]"
    end

    test "renders unknown block types as placeholders instead of dropping them" do
      blocks = [%{"type" => "audio", "data" => "..."}]

      assert ToolResultEnvelope.display_text(blocks) == "[unsupported content block: audio]"
    end

    test "skips empty and malformed text blocks" do
      blocks = [%{"type" => "text", "text" => ""}, %{"type" => "text"}, %{"no" => "type"}]

      assert ToolResultEnvelope.display_text(blocks) == ""
    end
  end

  describe "redact_blocks/1" do
    test "replaces envelope tool_result content with its text rendering" do
      envelope = envelope_string([%{"type" => "text", "text" => "shot.png"}, image_block()])

      blocks = [
        %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => envelope}
      ]

      assert [redacted] = ToolResultEnvelope.redact_blocks(blocks)
      assert redacted["content"] == "shot.png\n[image omitted]"
      assert redacted["tool_use_id"] == "toolu_1"
    end

    test "handles atom-keyed blocks" do
      envelope = envelope_string([image_block()])
      blocks = [%{type: "tool_result", tool_use_id: "toolu_1", content: envelope}]

      assert [%{content: "[image omitted]"}] = ToolResultEnvelope.redact_blocks(blocks)
    end

    test "leaves legacy tool_result blocks and other block types unchanged" do
      blocks = [
        %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "plain output"},
        %{"type" => "text", "text" => "hello"}
      ]

      assert ToolResultEnvelope.redact_blocks(blocks) == blocks
    end

    test "passes non-list content through unchanged" do
      assert ToolResultEnvelope.redact_blocks("plain string") == "plain string"
      assert ToolResultEnvelope.redact_blocks(nil) == nil
    end
  end
end
