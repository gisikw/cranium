defmodule Cranium.Egress.IncrementalTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Manifest

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    # Egress is a singleton GenServer — Mox calls happen in its process,
    # so we need global mode. Restart Egress if it crashed in a prior test.
    unless Process.whereis(Cranium.Egress) do
      Cranium.Egress.start_link([])
    end

    :ok
  end

  defp simulate_stream(stream_id, chunks, disposition \\ ["text"]) do
    egress = Process.whereis(Cranium.Egress)

    # Init manifest
    :ok = Manifest.init_stream(stream_id, "conv1", disposition: disposition)

    # Stream start
    send(egress, {:stream_start, stream_id, %{
      disposition: disposition,
      mode: :text
    }})

    # Send chunks with small delays to ensure ordering
    for chunk <- chunks do
      send(egress, {:chunk, stream_id, chunk})
    end

    # Stream end
    send(egress, {:stream_end, stream_id})

    # Give Egress time to process all messages
    Process.sleep(50)
  end

  describe "paragraph-boundary segmentation" do
    test "single paragraph becomes one segment on stream_end" do
      sid = "incr-single-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["Hello ", "world. ", "This is a test."])

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 1
      assert {:ok, "Hello world. This is a test."} = Manifest.get_segment_text(sid, 0)
    end

    test "two paragraphs become two segments" do
      sid = "incr-two-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["First paragraph.", "\n\n", "Second paragraph."])

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 2
      assert {:ok, "First paragraph."} = Manifest.get_segment_text(sid, 0)
      assert {:ok, "Second paragraph."} = Manifest.get_segment_text(sid, 1)
    end

    test "paragraph boundary mid-chunk splits correctly" do
      sid = "incr-mid-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["First para.\n\nSecond ", "para."])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
      assert {:ok, "First para."} = Manifest.get_segment_text(sid, 0)
      assert {:ok, "Second para."} = Manifest.get_segment_text(sid, 1)
    end

    test "three paragraphs with multiple boundaries" do
      sid = "incr-three-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["One.\n\nTwo.\n\nThree."])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 3
      assert {:ok, "One."} = Manifest.get_segment_text(sid, 0)
      assert {:ok, "Two."} = Manifest.get_segment_text(sid, 1)
      assert {:ok, "Three."} = Manifest.get_segment_text(sid, 2)
    end

    test "segments appear incrementally before stream_end" do
      sid = "incr-live-#{System.unique_integer([:positive])}"
      egress = Process.whereis(Cranium.Egress)

      :ok = Manifest.init_stream(sid, "conv1", disposition: ["text"])
      send(egress, {:stream_start, sid, %{disposition: ["text"], mode: :text}})
      send(egress, {:chunk, sid, "First paragraph.\n\n"})
      Process.sleep(20)

      # First segment should be in manifest while stream is still open
      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "streaming"
      assert length(manifest["segments"]) == 1
      assert {:ok, "First paragraph."} = Manifest.get_segment_text(sid, 0)

      # Now send more and end
      send(egress, {:chunk, sid, "Second."})
      send(egress, {:stream_end, sid})
      Process.sleep(20)

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 2
    end

    test "empty paragraphs are skipped" do
      sid = "incr-empty-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["Hello.\n\n\n\n\n\nWorld."])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
    end
  end

  describe "disposition-driven TTS warming" do
    test "audio disposition eagerly warms TTS cache for each segment" do
      sid = "incr-tts-#{System.unique_integer([:positive])}"

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn "First.", [] -> {:ok, <<1, 2, 3>>} end)
      |> expect(:synthesize, fn "Second.", [] -> {:ok, <<4, 5, 6>>} end)

      simulate_stream(sid, ["First.\n\nSecond."], ["audio", "text"])

      # Audio should be in cache (eager warming)
      assert {:ok, <<1, 2, 3>>} = Cranium.TTS.Cache.get(sid, 0)
      assert {:ok, <<4, 5, 6>>} = Cranium.TTS.Cache.get(sid, 1)
    end

    test "text-only disposition does not call TTS" do
      sid = "incr-notts-#{System.unique_integer([:positive])}"

      # No TTS mock expectations — would fail if called
      simulate_stream(sid, ["Hello.\n\nWorld."], ["text"])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
    end
  end
end
