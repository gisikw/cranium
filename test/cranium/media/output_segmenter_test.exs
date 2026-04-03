defmodule Cranium.Media.OutputSegmenterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Manifest

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    unless Process.whereis(Cranium.Media.OutputSegmenter) do
      Cranium.Media.OutputSegmenter.start_link([])
    end

    :ok
  end

  # Helper: generate N words of filler text
  defp words(n), do: Enum.map_join(1..n, " ", fn i -> "word#{i}" end)

  defp simulate_stream(stream_id, chunks, disposition \\ ["text"]) do
    segmenter = Process.whereis(Cranium.Media.OutputSegmenter)

    :ok = Manifest.init_stream(stream_id, "conv1", disposition: disposition)

    send(
      segmenter,
      {:stream_start, stream_id,
       %{
         disposition: disposition,
         mode: :text
       }}
    )

    for chunk <- chunks do
      send(segmenter, {:chunk, stream_id, chunk})
    end

    send(segmenter, {:stream_end, stream_id})

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
      segmenter = Process.whereis(Cranium.Media.OutputSegmenter)

      :ok = Manifest.init_stream(sid, "conv1", disposition: ["text"])
      send(segmenter, {:stream_start, sid, %{disposition: ["text"], mode: :text}})
      send(segmenter, {:chunk, sid, words(35) <> "\n\n"})
      Process.sleep(20)

      # First segment should appear while stream is still open
      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "streaming"
      assert length(manifest["segments"]) == 1

      send(segmenter, {:chunk, sid, "More text."})
      send(segmenter, {:stream_end, sid})
      Process.sleep(20)

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 2
    end
  end

  describe "cue segment ordering" do
    test "tool call first (no text) creates cue at index 0, no empty utterance" do
      sid = "incr-cue-first-#{System.unique_integer([:positive])}"
      tool_data = %{id: "t1", name: "Read", input: %{"file_path" => "/foo"}}

      simulate_stream(sid, [{:tool_use, tool_data}])

      {:ok, manifest} = Manifest.get(sid)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 1

      [seg] = manifest["segments"]
      assert seg["type"] == "cue"
      assert seg["index"] == 0
    end

    test "tool call before text gets sequential indices" do
      sid = "incr-cue-then-text-#{System.unique_integer([:positive])}"
      tool_data = %{id: "t1", name: "Bash", input: %{"command" => "ls"}}

      simulate_stream(sid, [{:tool_use, tool_data}, "Here are the results."])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 2

      [cue, utt] = manifest["segments"]
      assert cue["type"] == "cue"
      assert cue["index"] == 0
      assert utt["type"] == "utterance"
      assert utt["index"] == 1

      # Utterance text is fetchable (no 404)
      {:ok, text} = Manifest.get_segment_text(sid, 1)
      assert text =~ "results"
    end

    test "text then tool call flushes buffered text before cue" do
      sid = "incr-text-then-cue-#{System.unique_integer([:positive])}"
      tool_data = %{id: "t1", name: "Read", input: %{"file_path" => "/bar"}}

      simulate_stream(sid, ["Some context here.", {:tool_use, tool_data}, "And more after."])

      {:ok, manifest} = Manifest.get(sid)
      assert length(manifest["segments"]) == 3

      [utt0, cue, utt1] = manifest["segments"]
      assert utt0["type"] == "utterance"
      assert utt0["index"] == 0
      assert cue["type"] == "cue"
      assert cue["index"] == 1
      assert utt1["type"] == "utterance"
      assert utt1["index"] == 2

      {:ok, text0} = Manifest.get_segment_text(sid, 0)
      assert text0 =~ "context"
      {:ok, text2} = Manifest.get_segment_text(sid, 2)
      assert text2 =~ "more after"
    end

    test "multiple consecutive tool calls get sequential indices" do
      sid = "incr-multi-cue-#{System.unique_integer([:positive])}"
      t1 = %{id: "t1", name: "Read", input: %{}}
      t2 = %{id: "t2", name: "Bash", input: %{}}

      simulate_stream(sid, [
        {:tool_use, t1},
        {:tool_result, %{tool_use_id: "t1"}},
        {:tool_use, t2}
      ])

      {:ok, manifest} = Manifest.get(sid)
      indices = Enum.map(manifest["segments"], & &1["index"])
      assert indices == Enum.uniq(indices), "all segment indices should be unique"
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

    test "aggressive mode sentence-splits large paragraphs instead of emitting whole" do
      sid = "incr-agg-split-#{System.unique_integer([:positive])}"

      # Build a paragraph with multiple sentences totaling ~40 words.
      # In audio mode with no lead time, aggressive mode should sentence-split
      # this rather than emitting the entire paragraph as one segment.
      sentence1 = "The quick brown fox jumps over the lazy dog near the river."
      sentence2 = "A second sentence follows with enough words to be meaningful."
      sentence3 = "The third sentence completes this test paragraph nicely."
      paragraph = "#{sentence1} #{sentence2} #{sentence3}"

      # Allow any number of synthesize calls (we just care about segmentation)
      Cranium.Backend.TTS.Mock
      |> stub(:synthesize, fn _text, [] -> {:ok, <<0>>} end)

      simulate_stream(sid, [paragraph, "\n\n", "Final."], ["audio", "text"])

      {:ok, manifest} = Manifest.get(sid)
      utterances = Enum.filter(manifest["segments"], &(&1["type"] == "utterance"))

      # Should produce more than 2 segments (paragraph + final).
      # With sentence splitting, we expect 3+ segments from the paragraph
      # plus the "Final." segment.
      assert length(utterances) >= 3,
        "Expected aggressive mode to sentence-split the paragraph into multiple segments, " <>
          "got #{length(utterances)} segments"

      # First segment should be shorter than the full paragraph
      {:ok, first_text} = Manifest.get_segment_text(sid, 0)
      first_words = length(String.split(first_text, ~r/\s+/, trim: true))
      paragraph_words = length(String.split(paragraph, ~r/\s+/, trim: true))

      assert first_words < paragraph_words,
        "First segment (#{first_words} words) should be smaller than full paragraph (#{paragraph_words} words)"
    end
  end
end
