defmodule Cranium.Inference.TiamatTurnRequestTest do
  use CraniumTest.DataCase, async: false

  alias Cranium.Inference.TiamatTurnRequest

  @moduletag :capture_log

  defp text_block(text), do: [%{"type" => "text", "text" => text}]

  describe "assemble/1" do
    test "builds the Tiamat request shape with prompt layers and native messages" do
      conversation_id = "tiamat-request-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)
      parent_id = Ecto.UUID.generate()

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: text_block("previous"),
          parent_id: parent_id,
          origin: "cranium",
          provenance: %{"backend" => "test"}
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo-tiamat",
          request_id: "req-1",
          system_prompt_pre: [
            %{id: "identity", text: "You are Exo."},
            %{"id" => "room", "text" => "Work the routing ticket."}
          ],
          system_prompt_post: [%{id: "caller-final", text: "Emit native tool calls."}],
          tools_disabled: true
        )

      assert request["schema"] == "tiamat.turn.request.v1"
      assert request["request_id"] == "req-1"
      assert request["session_key"] == "cranium:#{conversation_id}:#{epoch_id}"
      assert request["router_profile"] == "exo-tiamat"

      assert request["system_prompt"] == %{
               "pre" => [
                 %{"id" => "identity", "text" => "You are Exo."},
                 %{"id" => "room", "text" => "Work the routing ticket."}
               ],
               "post" => [%{"id" => "caller-final", "text" => "Emit native tool calls."}]
             }

      assert request["tools"] == []

      [message] = request["messages"]
      assert message["id"]
      assert message["parent_id"] == parent_id
      assert message["created_at"] =~ "T"
      assert message["role"] == "assistant"
      assert message["content"] == text_block("previous")
      assert message["provenance"] == %{"origin" => "cranium", "backend" => "test"}
    end

    test "uses system_prompt as a pre fragment fallback" do
      conversation_id = "tiamat-request-prompt-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          system_prompt: "Core prompt",
          tools_disabled: true
        )

      assert request["system_prompt"]["pre"] == [
               %{"id" => "cranium-system", "text" => "Core prompt"}
             ]

      assert request["system_prompt"]["post"] == []
    end

    test "can pre-persist the current user message before native history build" do
      conversation_id = "tiamat-request-current-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("first")
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          append_current_user: true,
          current_user_text: "second",
          current_user_parent_id: :last_message,
          origin: "maw",
          current_user_provenance: %{"origin" => "maw", "source" => "test"},
          tools_disabled: true
        )

      [first, second] = request["messages"]
      assert first["content"] == text_block("first")
      assert second["content"] == text_block("second")
      assert second["parent_id"] == first["id"]
      assert second["provenance"] == %{"origin" => "maw", "source" => "test"}

      {:ok, stored} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)
      assert length(stored) == 2
    end

    test "projects persisted image blocks into Tiamat native history" do
      conversation_id = "tiamat-request-image-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      image_block = %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => "image/png",
          "data" => Base.encode64("png")
        }
      }

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [image_block, %{"type" => "text", "text" => "what is this?"}],
          origin: "matrix:headjack"
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          tools_disabled: true
        )

      [message] = request["messages"]
      assert message["role"] == "user"

      assert message["content"] == [
               %{
                 "type" => "image",
                 "image_media_type" => "image/png",
                 "image_data" => Base.encode64("png")
               },
               %{"type" => "text", "text" => "what is this?"}
             ]
    end

    test "omits persisted messages whose projected content is empty" do
      conversation_id = "tiamat-request-empty-message-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("first")
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: [%{"type" => "text", "text" => ""}]
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("second")
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          tools_disabled: true
        )

      assert Enum.map(request["messages"], & &1["content"]) == [
               text_block("first"),
               text_block("second")
             ]
    end

    test "drops empty persisted text blocks when projecting image history" do
      conversation_id = "tiamat-request-image-empty-text-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      image_block = %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => "image/png",
          "data" => Base.encode64("png")
        }
      }

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [image_block, %{"type" => "text", "text" => ""}],
          origin: "matrix:headjack"
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          tools_disabled: true
        )

      [message] = request["messages"]

      assert message["content"] == [
               %{
                 "type" => "image",
                 "image_media_type" => "image/png",
                 "image_data" => Base.encode64("png")
               }
             ]
    end

    test "delivers persisted tool_result envelope strings byte-identical" do
      conversation_id = "tiamat-request-envelope-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      envelope =
        Jason.encode!(%{
          "type" => "content",
          "content" => [
            %{"type" => "text", "text" => "screenshot.png: image/png, 60000 bytes"},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => Base.encode64(:crypto.strong_rand_bytes(60_000))
              }
            }
          ]
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: [
            %{"type" => "tool_use", "id" => "toolu_img", "name" => "read", "input" => %{}}
          ],
          origin: "cranium"
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: [
            %{"type" => "tool_result", "tool_use_id" => "toolu_img", "content" => envelope}
          ],
          origin: "cranium"
        })

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo",
          tools_disabled: true
        )

      [_tool_use_message, tool_message] = request["messages"]
      assert tool_message["role"] == "tool"

      assert [tool_result_block] = tool_message["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_result_for"] == "toolu_img"
      assert tool_result_block["tool_output"] == %{"content" => envelope}
    end

    test "includes tool definitions unless disabled" do
      conversation_id = "tiamat-request-tools-#{System.unique_integer([:positive])}"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      request =
        TiamatTurnRequest.assemble(
          conversation_id: conversation_id,
          epoch_id: epoch_id,
          router_profile: "exo"
        )

      assert Enum.any?(request["tools"], &(&1["name"] == "clear_context"))
      clear_context = Enum.find(request["tools"], &(&1["name"] == "clear_context"))
      assert clear_context["input_schema"]["type"] == "object"
    end
  end
end
