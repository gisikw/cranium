defmodule CraniumTest.StoreTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  # Store is started by the application supervisor; DataCase handles DB sandbox.

  defp text_block(text), do: [%{"type" => "text", "text" => text}]

  describe "append_message/get_messages" do
    setup do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-msg")
      %{epoch_id: epoch_id}
    end

    test "inserts messages and retrieves them in insertion order", %{epoch_id: epoch_id} do
      {:ok, _} =
        Cranium.Store.append_message("conv-msg", epoch_id, %{
          role: :user,
          content: text_block("hello")
        })

      {:ok, _} =
        Cranium.Store.append_message("conv-msg", epoch_id, %{
          role: :assistant,
          content: text_block("hi there")
        })

      {:ok, _} =
        Cranium.Store.append_message("conv-msg", epoch_id, %{
          role: :user,
          content: text_block("how are you?")
        })

      {:ok, messages} = Cranium.Store.get_messages("conv-msg")

      assert length(messages) == 3
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]

      assert Enum.map(messages, &Cranium.Store.extract_text(&1.content)) == [
               "hello",
               "hi there",
               "how are you?"
             ]
    end

    test "round-trips native transcript metadata", %{epoch_id: epoch_id} do
      parent_id = Ecto.UUID.generate()

      provenance = %{
        "origin" => "cranium",
        "backend" => "tiamat",
        "provider" => "anthropic",
        "model" => "claude-sonnet-4-6",
        "provider_request_id" => "req-123",
        "provider_message_id" => "msg-456"
      }

      {:ok, _} =
        Cranium.Store.append_message("conv-msg", epoch_id, %{
          role: :assistant,
          content: text_block("with provenance"),
          parent_id: parent_id,
          origin: "maw",
          usage: %{model: "claude-sonnet-4-6", input_tokens: 10, output_tokens: 3},
          provenance: provenance
        })

      {:ok, [message]} = Cranium.Store.get_messages("conv-msg", epoch_id: epoch_id)

      assert message.id
      assert message.conversation_id == "conv-msg"
      assert message.epoch_id == epoch_id
      assert message.parent_id == parent_id
      assert message.role == :assistant
      assert message.origin == "maw"
      assert message.usage["model"] == "claude-sonnet-4-6"
      assert message.provenance == provenance
      assert %DateTime{} = message.inserted_at
    end

    test "respects the limit option, returning most recent", %{epoch_id: epoch_id} do
      for i <- 1..10 do
        {:ok, _} =
          Cranium.Store.append_message("conv-msg", epoch_id, %{
            role: :user,
            content: text_block("msg #{i}")
          })
      end

      {:ok, messages} = Cranium.Store.get_messages("conv-msg", limit: 3)

      assert length(messages) == 3

      assert Enum.map(messages, &Cranium.Store.extract_text(&1.content)) == [
               "msg 8",
               "msg 9",
               "msg 10"
             ]
    end

    test "returns empty list when no messages exist" do
      {:ok, messages} = Cranium.Store.get_messages("nonexistent")
      assert messages == []
    end

    test "isolates messages by conversation_id" do
      {:ok, epoch_a} = Cranium.Store.create_epoch("conv-a")
      {:ok, epoch_b} = Cranium.Store.create_epoch("conv-b")

      {:ok, _} =
        Cranium.Store.append_message("conv-a", epoch_a, %{
          role: :user,
          content: text_block("alpha")
        })

      {:ok, _} =
        Cranium.Store.append_message("conv-b", epoch_b, %{
          role: :user,
          content: text_block("bravo")
        })

      {:ok, a_msgs} = Cranium.Store.get_messages("conv-a")
      {:ok, b_msgs} = Cranium.Store.get_messages("conv-b")

      assert length(a_msgs) == 1
      assert Cranium.Store.extract_text(hd(a_msgs).content) == "alpha"
      assert length(b_msgs) == 1
      assert Cranium.Store.extract_text(hd(b_msgs).content) == "bravo"
    end
  end

  describe "apply_tiamat_normalization_delta" do
    test "applies assignments by id selector and index selector" do
      conversation_id = "conv-normalize"
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

      {:ok, [first, second]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)
      assigned_parent = Ecto.UUID.generate()
      index_parent = Ecto.UUID.generate()

      delta = %{
        "assignments" => [
          %{
            "selector" => %{"id" => first.id},
            "assigned" => %{
              "id" => Ecto.UUID.generate(),
              "parent_id" => assigned_parent,
              "created_at" => "2001-01-01T00:00:00Z",
              "provenance" => %{"normalized_by" => "tiamat"}
            }
          },
          %{
            "selector" => %{"index" => 1},
            "assigned" => %{"parent_id" => index_parent}
          }
        ]
      }

      request_messages = [
        %{"id" => first.id},
        %{"id" => second.id}
      ]

      assert {:ok, %{applied: 2, skipped: 0}} =
               Cranium.Store.apply_tiamat_normalization_delta(
                 conversation_id,
                 epoch_id,
                 request_messages,
                 delta
               )

      {:ok, [updated_first, updated_second]} =
        Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

      assert updated_first.id == first.id
      assert updated_first.inserted_at == first.inserted_at
      assert updated_first.parent_id == assigned_parent
      assert updated_first.provenance == %{"normalized_by" => "tiamat"}
      assert updated_second.parent_id == index_parent
    end

    test "applies content-block tool id assignments" do
      conversation_id = "conv-normalize-tools"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: [
            %{"type" => "tool_use", "tool_name" => "bash", "tool_input" => %{"command" => "pwd"}}
          ]
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :tool,
          content: [%{"type" => "tool_result", "tool_output" => %{"stdout" => "/tmp"}}]
        })

      {:ok, [assistant, tool]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

      delta = %{
        "assignments" => [
          %{
            "selector" => %{"id" => assistant.id},
            "content_index" => 0,
            "assigned_tool_use_id" => "toolu_tiamat_test"
          },
          %{
            "selector" => %{"id" => tool.id},
            "content_index" => 0,
            "assigned_tool_result_for" => "toolu_tiamat_test"
          }
        ]
      }

      assert {:ok, %{applied: 2, skipped: 0}} =
               Cranium.Store.apply_tiamat_normalization_delta(
                 conversation_id,
                 epoch_id,
                 [%{"id" => assistant.id}, %{"id" => tool.id}],
                 delta
               )

      {:ok, [updated_assistant, updated_tool]} =
        Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

      assert [%{"tool_use_id" => "toolu_tiamat_test"}] = updated_assistant.content
      assert [%{"tool_result_for" => "toolu_tiamat_test"}] = updated_tool.content
    end

    test "skips missing selectors and no-op assignments" do
      conversation_id = "conv-normalize-skip"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      parent_id = Ecto.UUID.generate()

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("one"),
          parent_id: parent_id,
          provenance: %{"origin" => "test"}
        })

      {:ok, [message]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

      delta = %{
        "assignments" => [
          %{"selector" => %{"index" => 99}, "assigned" => %{"parent_id" => Ecto.UUID.generate()}},
          %{"selector" => %{"id" => message.id}, "assigned" => %{"parent_id" => parent_id}}
        ]
      }

      assert {:ok, %{applied: 0, skipped: 2}} =
               Cranium.Store.apply_tiamat_normalization_delta(
                 conversation_id,
                 epoch_id,
                 [%{"id" => message.id}],
                 delta
               )

      {:ok, [unchanged]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)
      assert unchanged.parent_id == parent_id
      assert unchanged.provenance == %{"origin" => "test"}
    end
  end

  describe "list_messages" do
    test "includes native transcript metadata in API messages" do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-api")
      parent_id = Ecto.UUID.generate()
      provenance = %{"origin" => "tiamat", "model" => "test-model"}

      {:ok, _} =
        Cranium.Store.append_message("conv-api", epoch_id, %{
          role: :assistant,
          content: text_block("api visible"),
          parent_id: parent_id,
          provenance: provenance
        })

      {:ok, %{messages: [message], has_more: false}} = Cranium.Store.list_messages("conv-api")

      assert message.id
      assert message.epoch_id == epoch_id
      assert message.parent_id == parent_id
      assert message.provenance == provenance
      assert message.text == "api visible"
    end
  end

  describe "list_transcripts" do
    test "includes native transcript metadata in transcript export" do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-transcript")
      parent_id = Ecto.UUID.generate()
      provenance = %{"origin" => "tiamat", "provider_request_id" => "req-789"}

      {:ok, _} =
        Cranium.Store.append_message("conv-transcript", epoch_id, %{
          role: :assistant,
          content: text_block("export me"),
          parent_id: parent_id,
          provenance: provenance
        })

      since = DateTime.utc_now() |> DateTime.add(-60, :second)
      {:ok, [record]} = Cranium.Store.list_transcripts(room: "conv-transcript", since: since)

      assert record.id
      assert record.parent_id == parent_id
      assert record.provenance == provenance
      assert record.content == "export me"
      assert record.text == "export me"
      assert record.content_blocks == text_block("export me")
      assert record.epoch_id == epoch_id
    end

    test "exports Tiamat-canonical tool ids and tool results" do
      conversation_id = "conv-transcript-tools"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :assistant,
          content: [
            %{
              "type" => "tool_use",
              "tool_use_id" => "toolu_tiamat_test",
              "tool_name" => "bash",
              "tool_input" => %{"command" => "pwd"}
            }
          ]
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :tool,
          content: [
            %{
              "type" => "tool_result",
              "tool_result_for" => "toolu_tiamat_test",
              "tool_output" => %{"stdout" => "/tmp"},
              "is_error" => false
            }
          ]
        })

      since = DateTime.utc_now() |> DateTime.add(-60, :second)

      {:ok, [record, _tool_record]} =
        Cranium.Store.list_transcripts(room: conversation_id, since: since)

      assert record.tool_calls == [%{name: "bash", success: true}]
    end

    test "uses timestamp and id cursor for stable incremental export" do
      conversation_id = "conv-transcript-cursor"
      {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id)

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("first")
        })

      {:ok, _} =
        Cranium.Store.append_message(conversation_id, epoch_id, %{
          role: :user,
          content: text_block("second")
        })

      {:ok, [first, second]} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

      Cranium.Store.Repo.update_all(
        from(m in Cranium.Store.Message,
          where: m.id in ^[first.id, second.id]
        ),
        set: [inserted_at: first.inserted_at]
      )

      cursor_id = min(first.id, second.id)
      expected_id = max(first.id, second.id)

      {:ok, [record]} =
        Cranium.Store.list_transcripts(
          room: conversation_id,
          since: first.inserted_at,
          after_id: cursor_id
        )

      assert record.id == expected_id
    end
  end

  describe "create_epoch/update_epoch/get_epoch" do
    test "creates and retrieves an epoch" do
      {:ok, _id} = Cranium.Store.create_epoch("conv-1")
      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.status == "active"
      assert epoch.turn_count == 0
    end

    test "updates fields on an existing epoch" do
      {:ok, id} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.update_epoch(id, %{turn_count: 5, saturation: 0.3})

      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.turn_count == 5
      assert epoch.saturation == 0.3
    end

    test "returns :not_found when epoch does not exist" do
      assert Cranium.Store.get_epoch("nonexistent") == :not_found
    end

    test "stores system_prompt" do
      {:ok, id} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.update_epoch(id, %{system_prompt: "You are helpful."})

      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.system_prompt == "You are helpful."
    end
  end

  describe "save_handoff/get_latest_handoff" do
    test "stores handoff on epoch and retrieves it" do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.save_handoff(epoch_id, "handoff content")

      assert {:ok, "handoff content"} = Cranium.Store.get_latest_handoff("conv-1")
    end

    test "returns the most recent epoch's handoff" do
      {:ok, epoch_1} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.save_handoff(epoch_1, "first handoff")
      :ok = Cranium.Store.update_epoch(epoch_1, %{status: "cleared"})

      Process.sleep(1100)

      {:ok, epoch_2} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.save_handoff(epoch_2, "second handoff")

      assert {:ok, "second handoff"} = Cranium.Store.get_latest_handoff("conv-1")
    end

    test "returns :not_found when no handoffs exist" do
      assert Cranium.Store.get_latest_handoff("nonexistent") == :not_found
    end

    test "skips epochs without handoffs" do
      {:ok, epoch_1} = Cranium.Store.create_epoch("conv-1")
      :ok = Cranium.Store.save_handoff(epoch_1, "has handoff")
      :ok = Cranium.Store.update_epoch(epoch_1, %{status: "cleared"})

      Process.sleep(1100)

      # Second epoch has no handoff
      {:ok, _epoch_2} = Cranium.Store.create_epoch("conv-1")

      assert {:ok, "has handoff"} = Cranium.Store.get_latest_handoff("conv-1")
    end
  end

  describe "get_last_message_at/1" do
    test "returns the timestamp of the most recent message" do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-ts")

      {:ok, _} =
        Cranium.Store.append_message("conv-ts", epoch_id, %{
          role: :user,
          content: text_block("first")
        })

      Process.sleep(10)

      {:ok, _} =
        Cranium.Store.append_message("conv-ts", epoch_id, %{
          role: :assistant,
          content: text_block("second")
        })

      {:ok, ts} = Cranium.Store.get_last_message_at(epoch_id)
      assert %DateTime{} = ts
    end

    test "returns :not_found when no messages exist" do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-empty")
      assert :not_found = Cranium.Store.get_last_message_at(epoch_id)
    end
  end

  describe "save_summary/get_all_summaries" do
    test "returns all summaries ordered by most recent" do
      :ok = Cranium.Store.save_summary("conv-a", "alpha summary")
      Process.sleep(1100)
      :ok = Cranium.Store.save_summary("conv-b", "bravo summary")

      {:ok, summaries} = Cranium.Store.get_all_summaries()

      assert length(summaries) == 2
      assert hd(summaries).conversation_id == "conv-b"
      assert List.last(summaries).conversation_id == "conv-a"
    end

    test "upserts summary for same conversation_id" do
      :ok = Cranium.Store.save_summary("conv-1", "first version")
      :ok = Cranium.Store.save_summary("conv-1", "second version")

      {:ok, summaries} = Cranium.Store.get_all_summaries()
      assert length(summaries) == 1
      assert hd(summaries).content == "second version"
    end

    test "returns empty list when no summaries exist" do
      {:ok, summaries} = Cranium.Store.get_all_summaries()
      assert summaries == []
    end
  end
end
