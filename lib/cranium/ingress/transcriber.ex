defmodule Cranium.Ingress.Transcriber do
  @moduledoc """
  Routes audio to the STT backend and returns text.

  For events with audio content, sends the audio to the configured STT
  backend and replaces the audio with its transcription. Text-only events
  pass through unchanged.

  The STT backend is configured at the application level and implements
  the `Cranium.Backend.STT` behaviour. Currently Whisper (HTTP POST);
  will be Voxtral Mini Realtime (streaming WebSocket) in the future.
  """

  require Logger

  @spec process(map(), map()) :: {:ok, map()} | {:error, term()}
  def process(%{type: :audio, audio: audio} = event, _context) when is_binary(audio) do
    backend = backend_module()
    Logger.info("Transcribing audio", stage: :ingress, backend: backend)

    case backend.transcribe(audio, []) do
      {:ok, text} ->
        {:ok, %{event | type: :text, body: text, audio: nil}}

      {:error, reason} ->
        Logger.error("Transcription failed: #{inspect(reason)}", stage: :ingress)
        {:error, {:transcription_failed, reason}}
    end
  end

  def process(event, _context), do: {:ok, event}

  defp backend_module do
    Application.get_env(:cranium, :backends)[:stt] || Cranium.Backend.STT.Whisper
  end
end
