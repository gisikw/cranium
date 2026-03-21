defmodule Cranium.Backend.TTS do
  @moduledoc """
  Behaviour for Text-to-Speech backends.

  Implementations convert text to audio binary data. Current implementation
  is ExoVoice (OpenAI-compatible TTS endpoint).
  """

  @doc """
  Synthesize text to audio.

  `text` is the string to speak.
  `opts` may include voice selection, format, speed, etc.
  """
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
              {:ok, audio :: binary()} | {:error, term()}
end

defmodule Cranium.Backend.TTS.ExoVoice do
  @moduledoc """
  Exo TTS backend (OpenAI-compatible).

  Sends text to the Exo voice service at exo-tts.gisi.network.
  """

  @behaviour Cranium.Backend.TTS

  @impl true
  def synthesize(text, opts) do
    url = Keyword.get(opts, :url) || tts_url()
    format = Keyword.get(opts, :format, "mp3")

    payload = %{input: text, response_format: format}
    plug = Keyword.get(opts, :plug)

    req_opts =
      [json: payload, connect_options: [timeout: 10_000], receive_timeout: 120_000] ++
        if(plug, do: [plug: plug], else: [])

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
    Application.get_env(:cranium, :backends)[:tts_url] || "https://exo-tts.gisi.network/v1/audio/speech"
  end
end
