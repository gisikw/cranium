defmodule Cranium.Inference.TurnAssemblerCorrelationTest do
  @moduledoc """
  Take → transcription → committed message correlation.

  When an audio take's transcription commits as a user message, the
  `message.created` room event must carry the take's id as its
  `correlation_id` so clients can match a locally-held take to the
  committed message. Text passes have no take and stay nil.

  Drives the real pipeline: transcription_complete → TakeCollector →
  take_complete → TurnAssembler → RoomEvents.message_created.
  """

  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)

    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Cranium.Inference.ConversationDynamicSupervisor) do
      DynamicSupervisor.terminate_child(Cranium.Inference.ConversationDynamicSupervisor, pid)
    end

    :ok
  end

  # Pre-seed an epoch with turn_count > 0 so orientation doesn't fire.
  defp seed_epoch(conversation_id) do
    {:ok, epoch_id} = Cranium.Store.create_epoch(conversation_id, %{turn_count: 1})
    epoch_id
  end

  defp expect_one_turn do
    Cranium.Backend.LLM.Mock
    |> expect(:stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          send(caller, {:llm_text, "ack"})
          send(caller, {:llm_usage, %{input_tokens: 1_000, output_tokens: 100}})
          send(caller, {:llm_stop, "end_turn"})
        end)

      {:ok, pid}
    end)
  end

  test "take transcription commits with take_id as correlation_id" do
    conversation_id = "test-take-corr-#{System.unique_integer([:positive])}"
    take_id = "take-#{System.unique_integer([:positive])}"
    stream_id = "stream-#{System.unique_integer([:positive])}"
    seed_epoch(conversation_id)
    expect_one_turn()

    Cranium.Events.subscribe({:conversation, conversation_id})

    {:ok, _} = Cranium.Inference.Conversation.start_or_get(conversation_id)

    # Audio pass: header carries take_id (pass_id == take_id, as Transport does)
    header = %Cranium.Messages.PassHeader{
      pass_id: take_id,
      conversation_id: conversation_id,
      stream_id: stream_id,
      take_id: take_id,
      disposition: ["text"],
      ephemeral: false,
      origin: "hearth"
    }

    Cranium.Events.broadcast({:pass_header, header})

    # Single-segment transcription — the real TakeCollector assembles it
    # into a take_complete that TurnAssembler correlates via take_index.
    Cranium.Events.broadcast(
      {:transcription_complete,
       %Cranium.Messages.Transcription{text: "hello from a take", take_id: take_id, seq: nil}}
    )

    # The live broadcast envelope carries the take id
    assert_receive {:room_event, %{type: "message.created", correlation_id: ^take_id}}, 5000

    assert_receive {:pass_complete, ^conversation_id, ^stream_id, %{reason: :complete}}, 5000

    # The durable row (Room Sync catch-up path) carries it too
    {:ok, events} = Cranium.Store.list_room_events(conversation_id, 0)
    committed = Enum.find(events, &(&1.type == "message.created"))

    assert committed.correlation_id == take_id
    assert committed.payload["role"] == "user"
    assert committed.payload["preview"] =~ "hello from a take"
  end

  test "text pass commits with nil correlation_id" do
    conversation_id = "test-text-corr-#{System.unique_integer([:positive])}"
    pass_id = "pass-#{System.unique_integer([:positive])}"
    stream_id = "stream-#{System.unique_integer([:positive])}"
    seed_epoch(conversation_id)
    expect_one_turn()

    Cranium.Events.subscribe({:conversation, conversation_id})

    {:ok, _} = Cranium.Inference.Conversation.start_or_get(conversation_id)

    header = %Cranium.Messages.PassHeader{
      pass_id: pass_id,
      conversation_id: conversation_id,
      stream_id: stream_id,
      disposition: ["text"],
      ephemeral: false,
      origin: "test"
    }

    Cranium.Events.broadcast({:pass_header, header})

    Cranium.Events.broadcast(
      {:text_input, %Cranium.Messages.TextInput{pass_id: pass_id, text: "plain text message"}}
    )

    assert_receive {:room_event, %{type: "message.created", correlation_id: nil}}, 5000

    assert_receive {:pass_complete, ^conversation_id, ^stream_id, %{reason: :complete}}, 5000

    {:ok, events} = Cranium.Store.list_room_events(conversation_id, 0)
    committed = Enum.find(events, &(&1.type == "message.created"))

    assert committed.correlation_id == nil
    assert committed.payload["preview"] =~ "plain text message"
  end
end
