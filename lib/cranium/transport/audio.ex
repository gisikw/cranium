defmodule Cranium.Transport.Audio do
  @moduledoc """
  OpenAI-compatible audio endpoints handler.

  Provides `POST /v1/audio/speech` (TTS) and `POST /v1/audio/transcriptions`
  (STT) in the OpenAI wire format. Routes are declared in `Transport.HTTP`;
  this module owns the handler logic.

  ## Design

  Stateless, ephemeral endpoints. No epochs, no manifests, no conversation
  state. Each request is independent. Profile resolution works identically
  to chat completions: the `model` field maps to a cranium profile name.

  Voice/speed precedence (highest to lowest):
  1. Per-request parameters
  2. Profile audio config
  3. tts.yaml prosody
  4. Hardcoded defaults
  """

  require Logger

  @speech_max_input_length 4096
  @transcription_max_file_size 26_214_400

  @mime_types %{
    "mp3" => "audio/mpeg",
    "wav" => "audio/wav",
    "opus" => "audio/opus",
    "flac" => "audio/flac"
  }

  # --- POST /v1/audio/speech ---

  @doc "Handle POST /v1/audio/speech."
  @spec speech(Plug.Conn.t()) :: Plug.Conn.t()
  def speech(conn) do
    model = conn.body_params["model"]
    input = conn.body_params["input"]

    cond do
      is_nil(input) or input == "" ->
        error_response(conn, 400, "missing required field: input")

      is_binary(input) and String.length(input) > @speech_max_input_length ->
        error_response(
          conn,
          400,
          "input exceeds maximum length of #{@speech_max_input_length} characters"
        )

      true ->
        do_speech(conn, model, input)
    end
  end

  defp do_speech(conn, model, input) do
    case Cranium.Config.resolve_profile(model) do
      {:ok, profile} ->
        voice = conn.body_params["voice"] || profile.voice
        speed = conn.body_params["speed"] || profile.speed
        format = conn.body_params["response_format"] || profile.response_format || "mp3"

        opts =
          [format: format] ++
            if(voice, do: [voice: voice], else: []) ++
            if(speed, do: [speed: speed], else: []) ++
            if(profile.tts_url, do: [url: profile.tts_url], else: [])

        Logger.info("Audio speech: model=#{model} voice=#{voice || "default"} format=#{format}")

        case tts_backend().synthesize(input, opts) do
          {:ok, audio} ->
            content_type = Map.get(@mime_types, format, "application/octet-stream")

            conn
            |> Plug.Conn.put_resp_content_type(content_type)
            |> Plug.Conn.send_resp(200, audio)

          {:error, reason} ->
            Logger.error("Audio speech: TTS synthesis failed", error: inspect(reason))
            error_response(conn, 502, "TTS synthesis failed: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        error_response(conn, 404, "model '#{model}' not found")
    end
  end

  # --- POST /v1/audio/transcriptions ---

  @doc "Handle POST /v1/audio/transcriptions."
  @spec transcriptions(Plug.Conn.t()) :: Plug.Conn.t()
  def transcriptions(conn) do
    model = conn.body_params["model"]
    file = conn.body_params["file"]

    cond do
      not match?(%Plug.Upload{}, file) ->
        error_response(conn, 400, "missing required field: file")

      File.stat!(file.path).size > @transcription_max_file_size ->
        error_response(
          conn,
          400,
          "file exceeds maximum size of #{@transcription_max_file_size} bytes"
        )

      true ->
        do_transcriptions(conn, model, file)
    end
  end

  defp do_transcriptions(conn, model, file) do
    case Cranium.Config.resolve_profile(model) do
      {:ok, profile} ->
        audio = File.read!(file.path)
        language = conn.body_params["language"] || profile.stt_language

        opts =
          if(language, do: [language: language], else: []) ++
            if(profile.stt_url, do: [url: profile.stt_url], else: [])

        Logger.info(
          "Audio transcription: model=#{model} size=#{byte_size(audio)} language=#{language || "auto"}"
        )

        case stt_backend().transcribe(audio, opts) do
          {:ok, text} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"text" => text}))

          {:error, reason} ->
            Logger.error("Audio transcription: STT failed", error: inspect(reason))
            error_response(conn, 502, "transcription failed: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        error_response(conn, 404, "model '#{model}' not found")
    end
  end

  # --- Helpers ---

  defp error_response(conn, status, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => nil
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp tts_backend do
    Application.get_env(:cranium, :tts_backend, Cranium.Backend.TTS.ExoVoice)
  end

  defp stt_backend do
    Application.get_env(:cranium, :stt_backend, Cranium.Backend.STT.Whisper)
  end
end
