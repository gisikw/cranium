defmodule Cranium.Media.TakeCollectorTest do
  use ExUnit.Case, async: true

  alias Cranium.Messages.{Transcription, TakeComplete}

  setup do
    # Subscribe to Events so we receive take_complete broadcasts
    Cranium.Events.subscribe()
    :ok
  end

  describe "single-segment transcription" do
    test "emits take_complete immediately for seq: nil" do
      take_id = "single-#{System.unique_integer([:positive])}"

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "hello world", take_id: take_id, seq: nil}}
      )

      assert_receive {:take_complete, %TakeComplete{take_id: ^take_id, text: "hello world"}},
                     1000
    end

    test "ignores transcription without take_id" do
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "hello", take_id: nil, seq: nil}}
      )

      refute_receive {:take_complete, _}, 200
    end
  end

  describe "multi-segment transcription" do
    test "emits take_complete when sealed and all chunks received" do
      take_id = "multi-#{System.unique_integer([:positive])}"

      # Chunks arrive out of order
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "world", take_id: take_id, seq: 1}}
      )

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "hello ", take_id: take_id, seq: 0}}
      )

      # Not yet complete — no seal
      refute_receive {:take_complete, _}, 100

      # Seal the take
      Cranium.Events.broadcast({:take_sealed, take_id, 1})

      assert_receive {:take_complete, %TakeComplete{take_id: ^take_id, text: "hello world"}},
                     1000
    end

    test "emits take_complete when seal arrives before all chunks" do
      take_id = "seal-first-#{System.unique_integer([:positive])}"

      # Seal arrives first
      Cranium.Events.broadcast({:take_sealed, take_id, 2})

      # First two chunks
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "a", take_id: take_id, seq: 0}}
      )

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "b", take_id: take_id, seq: 1}}
      )

      refute_receive {:take_complete, _}, 100

      # Final chunk completes it
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "c", take_id: take_id, seq: 2}}
      )

      assert_receive {:take_complete, %TakeComplete{take_id: ^take_id, text: "abc"}}, 1000
    end

    test "assembles chunks in sequence order" do
      take_id = "order-#{System.unique_integer([:positive])}"

      # Chunks arrive in reverse order
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "third", take_id: take_id, seq: 2}}
      )

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "first", take_id: take_id, seq: 0}}
      )

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "second", take_id: take_id, seq: 1}}
      )

      Cranium.Events.broadcast({:take_sealed, take_id, 2})

      assert_receive {:take_complete,
                      %TakeComplete{take_id: ^take_id, text: "firstsecondthird"}},
                     1000
    end

    test "does not emit for incomplete take" do
      take_id = "incomplete-#{System.unique_integer([:positive])}"

      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "a", take_id: take_id, seq: 0}}
      )

      # Seal expects 3 chunks but only 1 received
      Cranium.Events.broadcast({:take_sealed, take_id, 2})

      refute_receive {:take_complete, _}, 200
    end
  end

  describe "transcription failure" do
    test "does not crash on single-segment failure" do
      Cranium.Events.broadcast(
        {:transcription_failed,
         %Transcription{failure: :timeout, take_id: "fail1", seq: nil}}
      )

      refute_receive {:take_complete, _}, 100
    end

    test "does not crash on chunked failure" do
      Cranium.Events.broadcast(
        {:transcription_failed,
         %Transcription{failure: :timeout, take_id: "fail2", seq: 1}}
      )

      refute_receive {:take_complete, _}, 100
    end

    test "failed chunk gets placeholder, take still completes" do
      take_id = "fail3"

      # Chunk 0 succeeds
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: "Hello ", take_id: take_id, seq: 0}}
      )

      # Chunk 1 fails
      Cranium.Events.broadcast(
        {:transcription_failed,
         %Transcription{failure: :timeout, take_id: take_id, seq: 1}}
      )

      # Chunk 2 succeeds
      Cranium.Events.broadcast(
        {:transcription_complete,
         %Transcription{text: " world", take_id: take_id, seq: 2}}
      )

      # Seal
      Cranium.Events.broadcast({:take_sealed, take_id, 2})

      assert_receive {:take_complete, %TakeComplete{take_id: ^take_id, text: text}}, 500
      assert text == "Hello [transcribed segment missing] world"
    end
  end
end
