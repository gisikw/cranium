defmodule Cranium.Inference.HistoryTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Inference.History

  @moduletag :capture_log

  defp text_block(text), do: [%{"type" => "text", "text" => text}]

  describe "contribute/2" do
    test "returns current message when no history exists" do
      conversation_id = "test-history-#{System.unique_integer([:positive])}"

      messages =
        History.contribute(conversation_id,
          text: "hello",
          attachments: []
        )

      assert length(messages) == 1
      assert List.last(messages) == %{"role" => "user", "content" => "hello"}
    end

    test "includes conversation history before current message" do
      conversation_id = "test-history-with-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      Cranium.Store.append_message(conversation_id, epoch_id, %{
        role: :user,
        content: text_block("first message")
      })

      Cranium.Store.append_message(conversation_id, epoch_id, %{
        role: :assistant,
        content: text_block("first reply")
      })

      messages =
        History.contribute(conversation_id,
          epoch_id: epoch_id,
          text: "second message",
          attachments: []
        )

      assert length(messages) == 3
      assert Enum.at(messages, 0) == %{"role" => "user", "content" => text_block("first message")}

      assert Enum.at(messages, 1) == %{
               "role" => "assistant",
               "content" => text_block("first reply")
             }

      assert Enum.at(messages, 2) == %{"role" => "user", "content" => "second message"}
    end

    test "handles image attachments in current message" do
      conversation_id = "test-history-img-#{System.unique_integer([:positive])}"

      attachment = %{
        type: :image,
        media_type: "image/png",
        data: <<137, 80, 78, 71>>
      }

      messages =
        History.contribute(conversation_id,
          text: "look at this",
          attachments: [attachment]
        )

      current = List.last(messages)
      assert current["role"] == "user"
      assert is_list(current["content"])

      [image_part, text_part] = current["content"]
      assert image_part["type"] == "image"
      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/png"
      assert image_part["source"]["data"] == Base.encode64(<<137, 80, 78, 71>>)
      assert text_part["type"] == "text"
      assert text_part["text"] == "look at this"
    end

    test "defaults to empty text when not provided" do
      conversation_id = "test-history-default-#{System.unique_integer([:positive])}"

      messages = History.contribute(conversation_id)

      assert length(messages) == 1
      assert List.last(messages) == %{"role" => "user", "content" => ""}
    end
  end
end
