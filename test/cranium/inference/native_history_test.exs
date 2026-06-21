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

      :ok =
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

      :ok =
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

    test "normalizes user tool_result messages as native tool role rows" do
      conversation_id = "native-history-result-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      :ok =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [
            %{type: "tool_result", tool_use_id: "toolu_1", content: "ok", is_error: false}
          ],
          origin: "cranium"
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_id)

      assert message.role == "tool"

      assert message.content == [
               %{
                 "type" => "tool_result",
                 "tool_result_for" => "toolu_1",
                 "tool_output" => %{"content" => "ok", "is_error" => false}
               }
             ]
    end

    test "keeps messages ordered by store history ordering" do
      conversation_id = "native-history-order-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      :ok =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("one")
        })

      :ok =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: text_block("two")
        })

      :ok =
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

      :ok =
        Cranium.Store.append_message(conversation_id, epoch_a, %{
          role: :user,
          content: text_block("old")
        })

      :ok =
        Cranium.Store.append_message(conversation_id, epoch_b, %{
          role: :user,
          content: text_block("new")
        })

      [message] = NativeHistory.contribute(conversation_id, epoch_id: epoch_b)

      assert message.content == text_block("new")
    end
  end
end
