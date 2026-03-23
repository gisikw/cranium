defmodule Cranium.EpochTest do
  use CraniumTest.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  # Store, Epoch.Registry, Epoch.Supervisor, and Effects.Supervisor are all
  # started by the application supervisor. DataCase handles DB sandbox.
  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
    :ok
  end

  describe "compute_saturation/1" do
    test "returns 0.0 for zero tokens" do
      assert Cranium.Epoch.compute_saturation(%{input_tokens: 0}) == 0.0
    end

    test "returns 0.5 at midpoint" do
      assert Cranium.Epoch.compute_saturation(%{input_tokens: 99_000, output_tokens: 1_000}) ==
               0.5
    end

    test "includes output_tokens in total" do
      assert Cranium.Epoch.compute_saturation(%{input_tokens: 0, output_tokens: 100_000}) == 0.5
    end

    test "sums all token types" do
      usage = %{
        input_tokens: 10_000,
        output_tokens: 10_000,
        cache_creation_input_tokens: 30_000,
        cache_read_input_tokens: 50_000
      }

      assert Cranium.Epoch.compute_saturation(usage) == 0.5
    end

    test "returns 1.0 at full capacity" do
      assert Cranium.Epoch.compute_saturation(%{input_tokens: 200_000}) == 1.0
    end

    test "clamps to 1.0 over limit" do
      assert Cranium.Epoch.compute_saturation(%{input_tokens: 300_000}) == 1.0
    end
  end

  describe "submit/2 — saturation tracking" do
    test "persists saturation and turn_count after inference" do
      conversation_id = "test-saturation-#{System.unique_integer([:positive])}"

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_usage, %{input_tokens: 99_000, output_tokens: 1_000}})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      {:ok, epoch_pid} = Cranium.Epoch.start_or_get(conversation_id)
      {:ok, _result} = Cranium.Epoch.submit(epoch_pid, "hello")

      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.saturation == 0.5
      assert epoch.turn_count == 1
      assert epoch.status == "active"
    end
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
      # Handoff generation requires a cc_session_id — inject one
      :sys.replace_state(epoch_pid, fn state -> %{state | cc_session_id: "test-session"} end)
      :ok = Cranium.Epoch.clear(epoch_pid)

      assert_receive {:handoff_task, handoff_pid}, 2000
      ref = Process.monitor(handoff_pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2000

      assert {:ok, "handoff content"} = Cranium.Store.get_latest_handoff(conversation_id)
    end
  end
end
