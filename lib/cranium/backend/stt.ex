defmodule Cranium.Backend.STT do
  @moduledoc """
  Behaviour for Speech-to-Text backends.

  Implementations convert audio binary data to text. Current implementation
  is Whisper (HTTP POST to a whisper service). Future: Voxtral Mini Realtime
  (streaming WebSocket).

  ## Streaming Extension

  When streaming STT becomes available, backends will also implement:
  - `start_stream/1` — begin a streaming transcription session
  - `push_audio/2` — send audio chunks
  - `end_stream/1` — finalize and get remaining text

  These callbacks will be added to this behaviour when needed. For now,
  `transcribe/2` handles complete audio buffers.
  """

  @doc """
  Transcribe audio to text.

  `audio` is a binary containing the complete audio data.
  `opts` may include format hints, language, etc.
  """
  @callback transcribe(audio :: binary(), opts :: keyword()) ::
              {:ok, text :: String.t()} | {:error, term()}
end

defmodule Cranium.Backend.STT.Whisper do
  @moduledoc """
  Whisper STT backend.

  Sends audio to a Whisper HTTP service endpoint and returns the
  transcription. The service URL is configured at the application level.
  """

  @behaviour Cranium.Backend.STT

  @impl true
  def transcribe(audio, opts) do
    url = Keyword.get(opts, :url) || stt_url()

    case Req.post(url, body: audio, headers: [{"content-type", "application/octet-stream"}]) do
      {:ok, %{status: 200, body: %{"text" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stt_url do
    Application.get_env(:cranium, :backends)[:stt_url] || "http://localhost:8787/transcribe"
  end
end
