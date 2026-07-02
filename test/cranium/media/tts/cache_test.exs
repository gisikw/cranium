defmodule Cranium.Media.TTS.CacheTest do
  # async: false because lazy synthesis reads from the global Manifest
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Cranium.Media.TTS.Cache

  setup :verify_on_exit!

  setup do
    name = :"cache_#{System.unique_integer([:positive])}"
    {:ok, _} = Cache.start_link(name: name, cleanup_delay: 50)
    %{cache: name}
  end

  describe "put/get with eager warming" do
    test "returns cached audio on repeated retrieval (evicted only by cleanup)", %{cache: cache} do
      audio = <<0xFF, 0xFB, 0x90, 0x00>>
      :ok = Cache.put("s1", 0, audio, cache)

      assert {:ok, ^audio} = Cache.get("s1", 0, cache)
      # Second retrieval still returns cached audio — entries persist
      # until the cleanup timer fires, preventing races between
      # concurrent readers.
      assert {:ok, ^audio} = Cache.get("s1", 0, cache)
    end

    test "multiple segments for same stream", %{cache: cache} do
      audio_0 = <<1, 2, 3>>
      audio_1 = <<4, 5, 6>>
      :ok = Cache.put("s1", 0, audio_0, cache)
      :ok = Cache.put("s1", 1, audio_1, cache)

      assert {:ok, ^audio_0} = Cache.get("s1", 0, cache)
      assert {:ok, ^audio_1} = Cache.get("s1", 1, cache)
    end

    test "different streams are isolated", %{cache: cache} do
      :ok = Cache.put("s1", 0, <<1>>, cache)
      :ok = Cache.put("s2", 0, <<2>>, cache)

      assert {:ok, <<1>>} = Cache.get("s1", 0, cache)
      assert {:ok, <<2>>} = Cache.get("s2", 0, cache)
    end
  end

  describe "lazy synthesis fallback" do
    test "synthesizes from manifest text on cache miss", %{cache: cache} do
      sid = "lazy-#{System.unique_integer([:positive])}"
      audio = <<0xFF, 0xFB>>

      # Broadcast segment_ready so Cache's text_cache gets populated
      Cranium.Events.broadcast(
        {:segment_ready, sid, 0, %{type: :utterance, text: "Hello world", renditions: [:text]}}
      )

      Process.sleep(10)

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn "Hello world", [] -> {:ok, audio} end)

      assert {:ok, ^audio} = Cache.get(sid, 0, cache)
    end

    test "returns error when segment text not found", %{cache: cache} do
      assert {:error, :segment_not_found} = Cache.get("nonexistent", 0, cache)
    end

    test "returns error when TTS backend fails", %{cache: cache} do
      sid = "lazy-fail-#{System.unique_integer([:positive])}"

      Cranium.Events.broadcast(
        {:segment_ready, sid, 0, %{type: :utterance, text: "Hello world", renditions: [:text]}}
      )

      Process.sleep(10)

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn "Hello world", [] -> {:error, :timeout} end)

      assert {:error, :timeout} = Cache.get(sid, 0, cache)
    end
  end

  describe "schedule_cleanup/2" do
    test "evicts unconsumed entries after delay", %{cache: cache} do
      :ok = Cache.put("s1", 0, <<1>>, cache)
      :ok = Cache.put("s1", 1, <<2>>, cache)
      :ok = Cache.put("s2", 0, <<3>>, cache)

      Cache.schedule_cleanup("s1", cache)

      # Entries still present before timer fires
      assert {:ok, <<1>>} = Cache.get("s1", 0, cache)

      # Wait for cleanup (50ms in test)
      Process.sleep(100)

      # s1 index 1 cleaned up (index 0 was already consumed via get above)
      assert {:error, :segment_not_found} = Cache.get("s1", 1, cache)

      # s2 entries unaffected
      assert {:ok, <<3>>} = Cache.get("s2", 0, cache)
    end

    test "reschedules if called again for same stream", %{cache: cache} do
      :ok = Cache.put("s1", 0, <<1>>, cache)

      Cache.schedule_cleanup("s1", cache)
      Process.sleep(25)
      # Reschedule — resets the timer
      Cache.schedule_cleanup("s1", cache)
      Process.sleep(35)

      # Would have fired by now with original timer (50ms),
      # but reschedule reset it so entry should still be there
      assert {:ok, <<1>>} = Cache.get("s1", 0, cache)
    end
  end
end
