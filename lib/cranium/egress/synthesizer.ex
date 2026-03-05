defmodule Cranium.Egress.Synthesizer do
  @moduledoc """
  Routes text chunks through the TTS backend for voice mode.

  Takes a list of text chunks and synthesizes each to audio. Markers
  pass through without synthesis.

  The TTS backend is configured at the application level and implements
  the `Cranium.Backend.TTS` behaviour.
  """

  require Logger

  @spec process([term()], map()) :: {:ok, [term()]}
  def process(chunks, _context) do
    backend = backend_module()

    results =
      Enum.map(chunks, fn
        %{type: :marker} = marker ->
          marker

        text when is_binary(text) ->
          case backend.synthesize(text, []) do
            {:ok, audio} ->
              %{type: :audio, data: audio, text: text}

            {:error, reason} ->
              Logger.error("TTS failed: #{inspect(reason)}", stage: :egress)
              # Fall back to text on TTS failure
              %{type: :text, data: text}
          end
      end)

    {:ok, results}
  end

  defp backend_module do
    Application.get_env(:cranium, :backends)[:tts] || Cranium.Backend.TTS.Kokoro
  end
end
