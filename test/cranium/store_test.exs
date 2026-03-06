defmodule CraniumTest.StoreTest do
  use CraniumTest.DataCase, async: false

  # Store is a named GenServer, so we need it running
  setup do
    start_supervised!(Cranium.Store)
    :ok
  end

  describe "append_message/get_messages" do
    test "inserts messages and retrieves them in insertion order" do
      :ok = Cranium.Store.append_message("conv-1", %{role: :user, content: "hello"})
      :ok = Cranium.Store.append_message("conv-1", %{role: :assistant, content: "hi there"})
      :ok = Cranium.Store.append_message("conv-1", %{role: :user, content: "how are you?"})

      {:ok, messages} = Cranium.Store.get_messages("conv-1")

      assert length(messages) == 3
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
      assert Enum.map(messages, & &1.content) == ["hello", "hi there", "how are you?"]
    end

    test "respects the limit option, returning most recent" do
      for i <- 1..10 do
        :ok = Cranium.Store.append_message("conv-2", %{role: :user, content: "msg #{i}"})
      end

      {:ok, messages} = Cranium.Store.get_messages("conv-2", limit: 3)

      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["msg 8", "msg 9", "msg 10"]
    end

    test "returns empty list when no messages exist" do
      {:ok, messages} = Cranium.Store.get_messages("nonexistent")
      assert messages == []
    end

    test "isolates messages by conversation_id" do
      :ok = Cranium.Store.append_message("conv-a", %{role: :user, content: "alpha"})
      :ok = Cranium.Store.append_message("conv-b", %{role: :user, content: "bravo"})

      {:ok, a_msgs} = Cranium.Store.get_messages("conv-a")
      {:ok, b_msgs} = Cranium.Store.get_messages("conv-b")

      assert length(a_msgs) == 1
      assert hd(a_msgs).content == "alpha"
      assert length(b_msgs) == 1
      assert hd(b_msgs).content == "bravo"
    end
  end

  describe "upsert_epoch/get_epoch" do
    test "inserts then updates, resulting in updated fields" do
      :ok = Cranium.Store.upsert_epoch("conv-1", %{status: "active", turn_count: 0})
      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.status == "active"
      assert epoch.turn_count == 0

      :ok = Cranium.Store.upsert_epoch("conv-1", %{turn_count: 5, saturation: 0.3})
      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.turn_count == 5
      assert epoch.saturation == 0.3
    end

    test "returns :not_found when epoch does not exist" do
      assert Cranium.Store.get_epoch("nonexistent") == :not_found
    end

    test "stores system_prompt" do
      :ok = Cranium.Store.upsert_epoch("conv-1", %{system_prompt: "You are helpful."})
      {:ok, epoch} = Cranium.Store.get_epoch("conv-1")
      assert epoch.system_prompt == "You are helpful."
    end
  end

  describe "save_handoff/get_latest_handoff" do
    test "returns the latest handoff when multiple exist" do
      :ok = Cranium.Store.save_handoff("conv-1", "first handoff")
      :ok = Cranium.Store.save_handoff("conv-1", "second handoff")
      :ok = Cranium.Store.save_handoff("conv-1", "third handoff")

      assert {:ok, "third handoff"} = Cranium.Store.get_latest_handoff("conv-1")
    end

    test "returns :not_found when no handoffs exist" do
      assert Cranium.Store.get_latest_handoff("nonexistent") == :not_found
    end

    test "isolates handoffs by conversation_id" do
      :ok = Cranium.Store.save_handoff("conv-a", "alpha handoff")
      :ok = Cranium.Store.save_handoff("conv-b", "bravo handoff")

      assert {:ok, "alpha handoff"} = Cranium.Store.get_latest_handoff("conv-a")
      assert {:ok, "bravo handoff"} = Cranium.Store.get_latest_handoff("conv-b")
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
