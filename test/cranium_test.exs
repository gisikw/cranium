defmodule CraniumTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
    :ok
  end

  describe "clear_epoch/1" do
    test "marks epoch cleared and creates a new one" do
      conversation_id = "test-clear-#{System.unique_integer([:positive])}"

      {:ok, _epoch_id} = Cranium.Store.create_epoch(conversation_id)
      {:ok, epoch_before} = Cranium.Store.get_epoch(conversation_id)
      assert epoch_before.status == "active"

      :ok = Cranium.clear_epoch(conversation_id)

      {:ok, epoch_after} = Cranium.Store.get_epoch(conversation_id)
      assert epoch_after.id != epoch_before.id
      assert epoch_after.status == "active"
      assert epoch_after.turn_count == 0
    end

    test "triggers handoff generation when cc_session_id exists" do
      conversation_id = "test-clear-handoff-#{System.unique_integer([:positive])}"
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()
        send(test_pid, {:handoff_task, self()})

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "handoff content"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      {:ok, _epoch_id} = Cranium.Store.create_epoch(conversation_id)
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      Cranium.Store.update_epoch(epoch.id, %{cc_session_id: "test-session"})

      :ok = Cranium.clear_epoch(conversation_id)

      assert_receive {:handoff_task, handoff_pid}, 2000
      ref = Process.monitor(handoff_pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5000

      assert {:ok, "handoff content"} = Cranium.Store.get_latest_handoff(conversation_id)
    end

    test "returns :ok when no epoch exists" do
      assert :ok = Cranium.clear_epoch("nonexistent-conversation")
    end
  end

  describe "cancel/1" do
    test "returns error when no active inference" do
      assert {:error, :no_active_inference} = Cranium.cancel("nonexistent")
    end
  end
end
