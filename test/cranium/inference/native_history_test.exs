defmodule Cranium.Inference.NativeHistoryTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Inference.NativeHistory

  @moduletag :capture_log

  defp text_block(text), do: [%{"type" => "text", "text" => text}]

  describe "contribute/2" do
    test "preserves durable row identity, timestamps, parentage, and provenance" do
      conversation_id = "native-history-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      parent_id = Ecto.UUID.generate()

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: text_block("hello"),
          parent_id: parent_id,
          origin: "maw",
          usage: %{model: "claude-sonnet-4-6"},
          provenance: %{"backend" => "tiamat", "provider_request_id" => "req-1"}
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert message.id
      assert message.parent_id == parent_id
      assert message.created_at =~ "T"
      assert message.role == "assistant"
      assert message.content == [%{"type" => "text", "text" => "hello"}]

      assert message.provenance == %{
               "origin" => "maw",
               "backend" => "tiamat",
               "provider_request_id" => "req-1",
               "model" => "claude-sonnet-4-6"
             }
    end

    test "normalizes assistant tool_use blocks with atom or string keys" do
      conversation_id = "native-history-tools-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: [
            %{type: "tool_use", id: "toolu_1", name: "bash", input: %{"command" => "pwd"}},
            %{"type" => "text", "text" => "checking"}
          ],
          origin: "cranium"
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert message.content == [
               %{
                 "type" => "tool_use",
                 "tool_use_id" => "toolu_1",
                 "tool_name" => "bash",
                 "tool_input" => %{"command" => "pwd"}
               },
               %{"type" => "text", "text" => "checking"}
             ]
    end

    test "reconstructs persisted ordinary tool output in the live canonical shape" do
      conversation_id = "native-history-result-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      output = ~s({"exit_code":0,"stderr":"","stdout":"ok"})

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [
            %{type: "tool_result", tool_use_id: "toolu_1", content: output, is_error: false}
          ],
          origin: "cranium"
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert message.role == "tool"

      assert message.content == [
               %{
                 "type" => "tool_result",
                 "tool_result_for" => "toolu_1",
                 "tool_output" => output,
                 "is_error" => false
               }
             ]
    end

    test "keeps persisted multimodal envelopes opaque and canonical" do
      conversation_id = "native-history-envelope-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      envelope =
        Jason.encode!(%{
          "type" => "content",
          "content" => [
            %{"type" => "text", "text" => "screenshot.png"},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => Base.encode64("png")
              }
            }
          ]
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [
            %{
              type: "tool_result",
              tool_use_id: "toolu_img",
              content: envelope,
              is_error: true
            }
          ],
          origin: "cranium"
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)
      [result] = message.content

      assert result["tool_output"] == envelope
      assert result["is_error"] == true
    end

    test "preserves already-canonical tool output and keeps is_error at block level" do
      conversation_id = "native-history-canonical-result-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      output = %{"stdout" => "ok", "exit_code" => 0}

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :tool,
          content: [
            %{
              type: "tool_result",
              tool_result_for: "toolu_2",
              tool_output: output,
              is_error: false
            }
          ],
          origin: "cranium"
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert message.content == [
               %{
                 "type" => "tool_result",
                 "tool_result_for" => "toolu_2",
                 "tool_output" => output,
                 "is_error" => false
               }
             ]
    end

    test "keeps messages ordered by store history ordering" do
      conversation_id = "native-history-order-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("one")
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: text_block("two")
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("three")
        })

      messages = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert Enum.map(messages, fn message -> List.first(message.content)["text"] end) == [
               "one",
               "two",
               "three"
             ]
    end

    test "scopes messages to the requested epoch" do
      conversation_id = "native-history-epoch-#{System.unique_integer([:positive])}"
      {:ok, epoch_a} = Cranium.Store.create_epoch(conversation_id)
      {:ok, epoch_b} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_a, %{
          role: :user,
          content: text_block("old")
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_b, %{
          role: :user,
          content: text_block("new")
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_b)

      assert message.content == text_block("new")
    end
  end
end
