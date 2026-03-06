defmodule Cranium.Egress.IncrementalTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Manifest

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    unless Process.whereis(Cranium.Egress) do
      Cranium.Egress.start_link([])
    end

    :ok
  end

  # Helper: generate N words of filler text
  defp words(n), do: Enum.map_join(1..n, " ", fn i -> "word#{i}" end)

  defp simulate_stream(stream_id, chunks, disposition \\ ["text"]) do
    egress = Process.whereis(Cranium.Egress)

    :ok = Manifest.init_stream(stream_id, "conv1", disposition: disposition)

    send(egress, {:stream_start, stream_id, %{
      disposition: disposition,
      mode: :text
    }})

    for chunk <- chunks do
      send(egress, {:chunk, stream_id, chunk})
    end

    send(egress, {:stream_end, stream_id})

    Process.sleep(50)
  end

  describe "word-threshold batching" do
    test "short paragraph (<30 words) emitted as single segment on stream_end" do
      sid = "incr-short-#{System.unique_integer([:positive])}"
      simulate_stream(sid, ["Hello world."])

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 1
    end

    test "first segment emits at paragraph break on or after 30 words" do
      sid = "incr-30-#{System.unique_integer([:positive])}"
      # 35 words then paragraph break, then 10 more
      simulate_stream(sid, [words(35), "\n\n", words(10)])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
      # First segment is the 35-word paragraph
      {:ok, first} = Manifest.get_segment_text(sid, 0)
      assert length(String.split(first, ~r/\s+/, trim: true)) == 35
    end

    test "short paragraphs merge until 30-word threshold" do
      sid = "incr-merge-#{System.unique_integer([:positive])}"
      # Two 10-word paragraphs (20 total, under 30), then a 15-word paragraph (35 total, over 30)
      simulate_stream(sid, [words(10), "\n\n", words(10), "\n\n", words(15), "\n\n", words(5)])

      {:ok, manifest} = Manifest.get(sid)
      # First three paragraphs merge into one segment (35 words >= 30)
      # Remaining 5 words become segment 2 on stream_end
      assert length(manifest["segments"]) == 2
    end

    test "subsequent segments use 100-word threshold" do
      sid = "incr-100-#{System.unique_integer([:positive])}"
      # First: 35 words (>= 30, emits)
      # Second: 50 words (< 100, accumulates)
      # Third: 60 words (50+60=110 >= 100, emits)
      # Fourth: 10 words (remainder, emits on stream_end)
      simulate_stream(sid, [words(35), "\n\n", words(50), "\n\n", words(60), "\n\n", words(10)])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 3

      {:ok, seg0} = Manifest.get_segment_text(sid, 0)
      assert length(String.split(seg0, ~r/\s+/, trim: true)) == 35

      {:ok, seg1} = Manifest.get_segment_text(sid, 1)
      # 50 + 60 merged (joined with \n\n, word count >= 100)
      wc = length(String.split(seg1, ~r/\s+/, trim: true))
      assert wc >= 100
    end

    test "paragraph at exactly 30 words emits as first segment" do
      sid = "incr-exact-#{System.unique_integer([:positive])}"
      simulate_stream(sid, [words(30), "\n\n", words(5)])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
    end

    test "segments appear incrementally before stream_end" do
      sid = "incr-live-#{System.unique_integer([:positive])}"
      egress = Process.whereis(Cranium.Egress)

      :ok = Manifest.init_stream(sid, "conv1", disposition: ["text"])
      send(egress, {:stream_start, sid, %{disposition: ["text"], mode: :text}})
      send(egress, {:chunk, sid, words(35) <> "\n\n"})
      Process.sleep(20)

      # First segment should appear while stream is still open
      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "streaming"
      assert length(manifest["segments"]) == 1

      send(egress, {:chunk, sid, "More text."})
      send(egress, {:stream_end, sid})
      Process.sleep(20)

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 2
    end
  end

  describe "disposition-driven TTS warming" do
    test "audio disposition eagerly warms TTS cache for each segment" do
      sid = "incr-tts-#{System.unique_integer([:positive])}"
      first_text = words(35)
      second_text = words(5)

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn ^first_text, [] -> {:ok, <<1, 2, 3>>} end)
      |> expect(:synthesize, fn ^second_text, [] -> {:ok, <<4, 5, 6>>} end)

      simulate_stream(sid, [first_text, "\n\n", second_text], ["audio", "text"])

      assert {:ok, <<1, 2, 3>>} = Cranium.TTS.Cache.get(sid, 0)
      assert {:ok, <<4, 5, 6>>} = Cranium.TTS.Cache.get(sid, 1)
    end

    test "text-only disposition does not call TTS" do
      sid = "incr-notts-#{System.unique_integer([:positive])}"

      simulate_stream(sid, [words(35), "\n\n", words(10)], ["text"])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2
    end
  end
end
