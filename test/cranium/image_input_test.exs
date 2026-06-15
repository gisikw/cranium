defmodule Cranium.ImageInputTest do
  use ExUnit.Case, async: true

  describe "openai_chat_part_to_internal/2" do
    test "preserves supported image data URL for vision profile" do
      profile = %{capabilities: %{"image_input" => true}}

      [block] =
        Cranium.ImageInput.openai_chat_part_to_internal(
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}
          },
          profile
        )

      assert block == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "aGVsbG8="
               }
             }
    end

    test "degrades image URL for non-vision profile" do
      [block] =
        Cranium.ImageInput.openai_chat_part_to_internal(
          %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}},
          %{capabilities: %{"image_input" => false}}
        )

      assert block["type"] == "text"
      assert block["text"] =~ "Image omitted"
      assert block["text"] =~ "selected profile does not support image input"
    end

    test "degrades malformed image data URL for vision profile" do
      [block] =
        Cranium.ImageInput.openai_chat_part_to_internal(
          %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,%%%"}},
          %{capabilities: %{"image_input" => true}}
        )

      assert block["type"] == "text"
      assert block["text"] =~ "malformed image payload"
    end
  end

  describe "internal image translation" do
    test "converts internal image to OpenAI Chat Completions part" do
      block = %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "abc"}
      }

      assert Cranium.ImageInput.internal_image_to_openai_chat_part(block) == %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/jpeg;base64,abc"}
             }
    end

    test "converts internal image to OpenAI Responses part" do
      block = %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "abc"}
      }

      assert Cranium.ImageInput.internal_image_to_responses_part(block) == %{
               "type" => "input_image",
               "image_url" => "data:image/jpeg;base64,abc"
             }
    end
  end
end
