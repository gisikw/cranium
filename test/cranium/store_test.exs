defmodule CraniumTest.StoreTest do
  use CraniumTest.DataCase, async: false

  # Store is started by the application supervisor; DataCase handles DB sandbox.

  describe "append_message/get_messages" do
    setup do
      {:ok, epoch_id} = Cranium.Store.create_epoch("conv-msg")
      %{epoch_id: epoch_id}
    end

    test "inserts messages and retrieves them in insertion order", %{epoch_id: epoch_id} do
      :ok = Cranium.Store.append_message("conv-msg", epoch_id, %{role: :user, content: "hello"})

      :ok =
        Cranium.Store.append_message("conv-msg", epoch_id, %{
          role: :assistant,
          content: "hi there"
        })

      :ok =
        Cranium.Store.append_message("conv-msg", epoch_id, %{role: :user, content: "how are you?"})

      {:ok, messages} = Cranium.Store.get_messages("conv-msg")

      assert length(messages) == 3
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
      assert Enum.map(messages, & &1.content) == ["hello", "hi there", "how are you?"]
    end

    test "respects the limit option, returning most recent", %{epoch_id: epoch_id} do
      for i <- 1..10 do
        :ok =
          Cranium.Store.append_message("conv-msg", epoch_id, %{role: :user, content: "msg #{i}"})
      end

      {:ok, messages} = Cranium.Store.get_messages("conv-msg", limit: 3)

      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["msg 8", "msg 9", "msg 10"]
    end

    test "returns empty list when no messages exist" do
      {:ok, messages} = Cranium.Store.get_messages("nonexistent")
      assert messages == []
    end

    test "isolates messages by conversation_id" do
      {:ok, epoch_a} = Cranium.Store.create_epoch("conv-a")
      {:ok, epoch_b} = Cranium.Store.create_epoch("conv-b")

      :ok = Cranium.Store.append_message("conv-a", epoch_a, %{role: :user, content: "alpha"})
      :ok = Cranium.Store.append_message("conv-b", epoch_b, %{role: :user, content: "bravo"})

      {:ok, a_msgs} = Cranium.Store.get_messages("conv-a")
      {:ok, b_msgs} = Cranium.Store.get_messages("conv-b")

      assert length(a_msgs) == 1
      assert hd(a_msgs).content == "alpha"
      assert length(b_msgs) == 1
      assert hd(b_msgs).content == "bravo"
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
      :ok = Cranium.Store.append_message("conv-ts", epoch_id, %{role: :user, content: "first"})
      Process.sleep(10)

      :ok =
        Cranium.Store.append_message("conv-ts", epoch_id, %{role: :assistant, content: "second"})

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
