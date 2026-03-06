defmodule Cranium.Egress.SynthesizerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Egress.Synthesizer

  setup :verify_on_exit!

  describe "process/2 in :voice mode" do
    test "text chunk is synthesized and returned as audio" do
      audio = <<1, 2, 3>>
      text = "Hello world"

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn ^text, [] -> {:ok, audio} end)

      {:ok, [result]} = Synthesizer.process([text], %{mode: :voice})
      assert result == %{type: :audio, data: audio, text: text}
    end

    test "markers pass through unchanged without calling TTS" do
      marker = %{type: :marker, id: "m1"}

      {:ok, [result]} = Synthesizer.process([marker], %{mode: :voice})
      assert result == marker
    end

    test "TTS failure falls back to {:type, :text, data: text}" do
      text = "Hello world"

      Cranium.Backend.TTS.Mock
      |> expect(:synthesize, fn ^text, [] -> {:error, :timeout} end)

      {:ok, [result]} = Synthesizer.process([text], %{mode: :voice})
      assert result == %{type: :text, data: text}
    end
  end

  describe "process/2 in :text mode" do
    test "text chunk passes through as %{type: :text} without calling TTS" do
      text = "Hello world"

      {:ok, [result]} = Synthesizer.process([text], %{mode: :text})
      assert result == %{type: :text, data: text}
    end

    test "markers pass through unchanged" do
      marker = %{type: :marker, id: "m2"}

      {:ok, [result]} = Synthesizer.process([marker], %{mode: :text})
      assert result == marker
    end
  end
end
