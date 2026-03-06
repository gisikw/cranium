defmodule Cranium.Ingress.TranscriberTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Ingress.Transcriber

  setup :verify_on_exit!

  describe "process/2" do
    test "audio event is transcribed and converted to text event" do
      audio = <<1, 2, 3>>

      Cranium.Backend.STT.Mock
      |> expect(:transcribe, fn ^audio, [] -> {:ok, "hello world"} end)

      assert {:ok, result} = Transcriber.process(%{type: :audio, audio: audio}, %{})
      assert result.type == :text
      assert result.body == "hello world"
      assert result.audio == nil
    end

    test "transcription failure returns error" do
      audio = <<1, 2, 3>>

      Cranium.Backend.STT.Mock
      |> expect(:transcribe, fn ^audio, [] -> {:error, :timeout} end)

      assert {:error, {:transcription_failed, :timeout}} =
               Transcriber.process(%{type: :audio, audio: audio}, %{})
    end

    test "text event passes through unchanged" do
      event = %{type: :text, body: "hello"}
      assert {:ok, ^event} = Transcriber.process(event, %{})
    end

    test "other event types pass through unchanged" do
      event = %{type: :image, url: "https://example.com/img.png"}
      assert {:ok, ^event} = Transcriber.process(event, %{})
    end
  end
end
