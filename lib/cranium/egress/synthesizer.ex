defmodule Cranium.Egress.Synthesizer do
  @moduledoc """
  Routes text chunks through the TTS backend for voice mode.

  Takes a list of paragraph-level text chunks (from Chunker) and synthesizes
  each to audio in `:voice` mode. In other modes, text chunks pass through
  as `%{type: :text, data: text}` without TTS. Markers always pass through
  unchanged.

  The TTS backend is configured at the application level and implements
  the `Cranium.Backend.TTS` behaviour.
  """

  require Logger

  @spec process([term()], map()) :: {:ok, [term()]}
  def process(chunks, context) do
    mode = Map.get(context, :mode)
    backend = backend_module()

    results =
      Enum.map(chunks, fn
        %{type: :marker} = marker ->
          marker

        text when is_binary(text) and mode == :voice ->
          case backend.synthesize(text, []) do
            {:ok, audio} ->
              %{type: :audio, data: audio, text: text}

            {:error, reason} ->
              Logger.error("TTS failed: #{inspect(reason)}", stage: :egress)
              # Fall back to text on TTS failure
              %{type: :text, data: text}
          end

        text when is_binary(text) ->
          %{type: :text, data: text}
      end)

    {:ok, results}
  end

  defp backend_module do
    Application.get_env(:cranium, :backends)[:tts] || Cranium.Backend.TTS.ExoVoice
  end
end
