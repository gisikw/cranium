defmodule Cranium.EpochTest do
  use CraniumTest.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!(Cranium.Store)
    start_supervised!({Registry, keys: :unique, name: Cranium.Epoch.Registry})
    start_supervised!({DynamicSupervisor, name: Cranium.Epoch.Supervisor, strategy: :one_for_one})
    start_supervised!({Task.Supervisor, name: Cranium.Effects.Supervisor})
    :ok
  end

  describe "clear/1" do
    test "triggers handoff generation and stores the result" do
      conversation_id = "test-clear-#{System.unique_integer([:positive])}"
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

      {:ok, epoch_pid} = Cranium.Epoch.start_or_get(conversation_id)
      :ok = Cranium.Epoch.clear(epoch_pid)

      assert_receive {:handoff_task, handoff_pid}, 2000
      ref = Process.monitor(handoff_pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2000

      assert {:ok, "handoff content"} = Cranium.Store.get_latest_handoff(conversation_id)
    end
  end
end
