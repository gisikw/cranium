defmodule Cranium.ManifestTest do
  use ExUnit.Case, async: true

  alias Cranium.Manifest

  setup do
    name = :"manifest_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Manifest.start_link(name: name)
    %{name: name}
  end

  describe "init_stream/3 + get/2" do
    test "initializes a stream with streaming status", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      {:ok, manifest} = Manifest.get("s1", name)

      assert manifest["stream_id"] == "s1"
      assert manifest["status"] == "streaming"
      assert manifest["segments"] == []
    end

    test "returns :not_found for unknown stream", %{name: name} do
      assert :not_found = Manifest.get("nope", name)
    end
  end

  describe "add_utterance/4" do
    test "default disposition (text-only) advertises only text rendition", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_utterance("s1", 0, "Hello world", name)

      {:ok, manifest} = Manifest.get("s1", name)
      [seg] = manifest["segments"]

      assert seg["index"] == 0
      assert seg["type"] == "utterance"
      assert seg["renditions"]["text"]["url"] == "/v1/streams/s1/segments/0/text"
      assert seg["renditions"]["text"]["mime"] == "text/plain"
      refute Map.has_key?(seg["renditions"], "audio")
    end

    test "returns error for unknown stream", %{name: name} do
      assert {:error, :not_found} = Manifest.add_utterance("nope", 0, "text", name)
    end

    test "segments accumulate in order", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_utterance("s1", 0, "First", name)
      :ok = Manifest.add_utterance("s1", 1, "Second", name)

      {:ok, manifest} = Manifest.get("s1", name)
      assert length(manifest["segments"]) == 2
      assert Enum.at(manifest["segments"], 0)["index"] == 0
      assert Enum.at(manifest["segments"], 1)["index"] == 1
    end
  end

  describe "disposition" do
    test "audio+text disposition advertises both renditions", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name, disposition: ["audio", "text"])
      :ok = Manifest.add_utterance("s1", 0, "Hello world", name)

      {:ok, manifest} = Manifest.get("s1", name)
      [seg] = manifest["segments"]

      assert seg["renditions"]["text"]["url"] == "/v1/streams/s1/segments/0/text"
      assert seg["renditions"]["audio"]["url"] == "/v1/streams/s1/segments/0/audio"
      assert seg["renditions"]["audio"]["mime"] == "audio/mp3"
    end

    test "audio-only disposition omits text rendition", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name, disposition: ["audio"])
      :ok = Manifest.add_utterance("s1", 0, "Hello world", name)

      {:ok, manifest} = Manifest.get("s1", name)
      [seg] = manifest["segments"]

      assert Map.has_key?(seg["renditions"], "audio")
      refute Map.has_key?(seg["renditions"], "text")
    end

    test "text stored internally regardless of disposition", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name, disposition: ["audio"])
      :ok = Manifest.add_utterance("s1", 0, "Hello world", name)

      assert {:ok, "Hello world"} = Manifest.get_segment_text("s1", 0, name)
    end
  end

  describe "add_cue/5" do
    test "adds cue segment with type and data", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_cue("s1", 0, :image, %{url: "https://example.com/img.png"}, name)

      {:ok, manifest} = Manifest.get("s1", name)
      [seg] = manifest["segments"]

      assert seg["index"] == 0
      assert seg["type"] == "cue"
      assert seg["cue_type"] == "image"
      assert seg["data"] == %{url: "https://example.com/img.png"}
    end

    test "returns error for unknown stream", %{name: name} do
      assert {:error, :not_found} = Manifest.add_cue("nope", 0, :image, %{}, name)
    end
  end

  describe "complete/2" do
    test "sets status to complete", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.complete("s1", name)

      {:ok, manifest} = Manifest.get("s1", name)
      assert manifest["status"] == "complete"
    end

    test "returns error for unknown stream", %{name: name} do
      assert {:error, :not_found} = Manifest.complete("nope", name)
    end
  end

  describe "get_segment_text/3" do
    test "returns text content for utterance segment", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_utterance("s1", 0, "Hello world", name)

      assert {:ok, "Hello world"} = Manifest.get_segment_text("s1", 0, name)
    end

    test "returns :not_found for missing stream", %{name: name} do
      assert :not_found = Manifest.get_segment_text("nope", 0, name)
    end

    test "returns :not_found for missing segment index", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      assert :not_found = Manifest.get_segment_text("s1", 99, name)
    end

    test "returns :not_found for cue segment", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_cue("s1", 0, :image, %{}, name)
      assert :not_found = Manifest.get_segment_text("s1", 0, name)
    end
  end

  describe "mixed segment types" do
    test "utterances and cues interleave correctly", %{name: name} do
      :ok = Manifest.init_stream("s1", "conv1", name: name)
      :ok = Manifest.add_utterance("s1", 0, "Before the image", name)
      :ok = Manifest.add_cue("s1", 1, :image, %{url: "img.png"}, name)
      :ok = Manifest.add_utterance("s1", 2, "After the image", name)
      :ok = Manifest.complete("s1", name)

      {:ok, manifest} = Manifest.get("s1", name)
      assert manifest["status"] == "complete"
      assert length(manifest["segments"]) == 3

      types = Enum.map(manifest["segments"], & &1["type"])
      assert types == ["utterance", "cue", "utterance"]
    end
  end
end
