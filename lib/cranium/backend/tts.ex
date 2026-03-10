defmodule Cranium.Backend.TTS do
  @moduledoc """
  Behaviour for Text-to-Speech backends.

  Implementations convert text to audio binary data. Current implementation
  is Kokoro (HTTP POST to the fort TTS service).
  """

  @doc """
  Synthesize text to audio.

  `text` is the string to speak.
  `opts` may include voice selection, format, speed, etc.
  """
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
              {:ok, audio :: binary()} | {:error, term()}
end

defmodule Cranium.Backend.TTS.Kokoro do
  @moduledoc """
  Kokoro TTS backend.

  Sends text to the Kokoro TTS service and returns audio data.
  """

  @behaviour Cranium.Backend.TTS

  @impl true
  def synthesize(text, opts) do
    url = Keyword.get(opts, :url) || tts_url()
    voice = Keyword.get(opts, :voice, "af_bella")
    format = Keyword.get(opts, :format, "mp3")

    payload = %{text: text, voice: voice, format: format}
    plug = Keyword.get(opts, :plug)

    req_opts = [json: payload] ++ if(plug, do: [plug: plug], else: [])

    case Req.post(url, req_opts) do
      {:ok, %{status: 200, body: audio}} when is_binary(audio) ->
        {:ok, audio}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tts_url do
    Application.get_env(:cranium, :backends)[:tts_url] || "https://tts.example.com/synthesize"
  end
end
