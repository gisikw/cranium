defmodule Cranium.Inference.HarnessTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)

    # Clean up any leftover conversation supervisors
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Cranium.Inference.ConversationDynamicSupervisor) do
      DynamicSupervisor.terminate_child(Cranium.Inference.ConversationDynamicSupervisor, pid)
    end

    :ok
  end

  # Flush Persistence.Effects mailbox to ensure async Store mutations complete.
  # GenServer messages are ordered: if pass_complete is in the mailbox before
  # :flush, the flush response guarantees mutations are done.
  defp flush_effects do
    GenServer.call(Cranium.Effects.PassReactor, :flush)
  end

  describe "compute_saturation/1" do
    test "returns 0.0 for zero tokens" do
      assert Cranium.Inference.Harness.compute_saturation(%{input_tokens: 0}) == 0.0
    end

    test "returns 0.5 at midpoint" do
      assert Cranium.Inference.Harness.compute_saturation(%{
               input_tokens: 99_000,
               output_tokens: 1_000
             }) == 0.5
    end

    test "clamps to 1.0 over limit" do
      assert Cranium.Inference.Harness.compute_saturation(%{input_tokens: 300_000}) == 1.0
    end

    test "uses explicit context_window when provided" do
      # 100k of 200k = 0.5 with default, but 100k of 262144 = ~0.38
      usage = %{input_tokens: 100_000}
      assert Cranium.Inference.Harness.compute_saturation(usage, 262_144) == 100_000 / 262_144
    end

    test "falls back to global config when context_window is nil" do
      # nil context_window should use Application config (200_000)
      assert Cranium.Inference.Harness.compute_saturation(%{input_tokens: 100_000}, nil) == 0.5
    end

    test "accepts usage maps with string keys" do
      assert Cranium.Inference.Harness.compute_saturation(%{
               "input_tokens" => 99_000,
               "output_tokens" => 1_000
             }) == 0.5
    end

    test "estimates saturation from assembled turn when usage is missing" do
      turn = %{
        system: String.duplicate("s", 400),
        system_prompt_pre: nil,
        system_prompt_post: nil,
        messages: [
          %{"role" => "user", "content" => String.duplicate("m", 400)}
        ]
      }

      assert_in_delta Cranium.Inference.Harness.compute_saturation(
                        %{input_tokens: 0, output_tokens: 0},
                        1_000,
                        turn,
                        String.duplicate("o", 200)
                      ),
                      0.25,
                      0.01
    end
  end

  # Pre-seed an epoch with turn_count > 0 so orientation doesn't fire.
  # Tests that care about orientation behavior test it explicitly.
  defp seed_epoch(conversation_id) do
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id, %{turn_count: 1})
    epoch_id
  end

  describe "TurnAssembler → Harness integration" do
    test "assembles context and runs inference on PassHeader + TextInput" do
      conversation_id = "test-harness-#{System.unique_integer([:positive])}"
      pass_id = "pass-#{System.unique_integer([:positive])}"
      stream_id = "stream-#{System.unique_integer([:positive])}"
      seed_epoch(conversation_id)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "hello from harness"})
            send(caller, {:llm_usage, %{input_tokens: 99_000, output_tokens: 1_000}})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      # Subscribe to pass_complete events
      Cranium.Events.subscribe({:conversation, conversation_id})

      # Start per-conversation infrastructure
      {:ok, _} = Cranium.Inference.Conversation.start_or_get(conversation_id)

      # Broadcast PassHeader + TextInput (mimics what Transport.HTTP does)
      header = %Cranium.Messages.PassHeader{
        pass_id: pass_id,
        conversation_id: conversation_id,
        stream_id: stream_id,
        model: nil,
        disposition: ["text"],
        ephemeral: false,
        system: nil,
        origin: "test"
      }

      Cranium.Events.broadcast({:pass_header, header})

      Cranium.Events.broadcast(
        {:text_input, %Cranium.Messages.TextInput{pass_id: pass_id, text: "hello world"}}
      )

      # Wait for pass_complete (enriched payload from Harness)
      assert_receive {:pass_complete, ^conversation_id, ^stream_id,
                      %{saturation: sat, turn_count: 2, reason: :complete}},
                     5000

      assert sat == 0.5

      # Flush Effects to ensure async Store mutations complete
      flush_effects()

      # Verify Store was updated (by Persistence.Effects)
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.saturation == 0.5
      assert epoch.turn_count == 2
      assert epoch.status == "active"

      # Verify user message was persisted (by TurnAssembler)
      # and assistant message was persisted (by Persistence.Effects)
      {:ok, messages} = Cranium.Store.get_messages(conversation_id)
      assert length(messages) >= 2
      assert Enum.any?(messages, fn m -> m.role == :user end)

      assert Enum.any?(messages, fn m ->
               m.role == :assistant and
                 Cranium.Store.extract_text(m.content) == "hello from harness"
             end)
    end

    test "handles cancellation and stores interrupted context" do
      conversation_id = "test-cancel-#{System.unique_integer([:positive])}"
      pass_id = "pass-#{System.unique_integer([:positive])}"
      stream_id = "stream-#{System.unique_integer([:positive])}"
      seed_epoch(conversation_id)
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "partial output"})
            # Signal test to cancel, then wait to be killed
            send(test_pid, :inference_started)
            Process.sleep(:infinity)
          end)

        {:ok, pid}
      end)

      # Subscribe to pass_complete events
      Cranium.Events.subscribe({:conversation, conversation_id})

      {:ok, _} = Cranium.Inference.Conversation.start_or_get(conversation_id)

      header = %Cranium.Messages.PassHeader{
        pass_id: pass_id,
        conversation_id: conversation_id,
        stream_id: stream_id,
        model: nil,
        disposition: ["text"],
        ephemeral: false,
        system: nil,
        origin: "test"
      }

      Cranium.Events.broadcast({:pass_header, header})

      Cranium.Events.broadcast(
        {:text_input, %Cranium.Messages.TextInput{pass_id: pass_id, text: "cancel me"}}
      )

      # Wait for inference to start, then cancel
      assert_receive :inference_started, 5000
      # Small delay to ensure Agent has registered
      Process.sleep(50)
      assert :ok = Cranium.Inference.Harness.cancel(conversation_id)

      # Wait for pass_complete with cancelled reason
      assert_receive {:pass_complete, ^conversation_id, ^stream_id, %{reason: :cancelled}}, 5000

      # Flush Effects to ensure async Store mutations complete
      flush_effects()

      # Verify interrupted_context was stored (by Persistence.Effects)
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.interrupted_context == "partial output"
    end

    test "backpressure queues second pass until first completes" do
      conversation_id = "test-backpressure-#{System.unique_integer([:positive])}"
      seed_epoch(conversation_id)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, 2, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "response"})
            send(caller, {:llm_usage, %{input_tokens: 1_000, output_tokens: 100}})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      Cranium.Events.subscribe({:conversation, conversation_id})

      {:ok, _} = Cranium.Inference.Conversation.start_or_get(conversation_id)

      # Send two passes in rapid succession
      for i <- 1..2 do
        pass_id = "pass-#{i}-#{System.unique_integer([:positive])}"
        stream_id = "stream-#{i}-#{System.unique_integer([:positive])}"

        header = %Cranium.Messages.PassHeader{
          pass_id: pass_id,
          conversation_id: conversation_id,
          stream_id: stream_id,
          model: nil,
          disposition: ["text"],
          ephemeral: false,
          system: nil,
          origin: "test"
        }

        Cranium.Events.broadcast({:pass_header, header})

        Cranium.Events.broadcast(
          {:text_input, %Cranium.Messages.TextInput{pass_id: pass_id, text: "msg #{i}"}}
        )
      end

      # Both passes should complete (second queued, dispatched after first)
      assert_receive {:pass_complete, ^conversation_id, _, %{reason: :complete}}, 5000
      assert_receive {:pass_complete, ^conversation_id, _, %{reason: :complete}}, 5000

      # Flush Effects to ensure async Store mutations complete
      flush_effects()

      # Verify two turns were counted (seeded at 1, +2 passes = 3)
      {:ok, epoch} = Cranium.Store.get_epoch(conversation_id)
      assert epoch.turn_count == 3
    end
  end
end
