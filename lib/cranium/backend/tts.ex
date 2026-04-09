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
  TTS backend (OpenAI-compatible).

  Sends text to the configured TTS endpoint (TTS_URL env var).
  Prosody settings (voice, speed) are loaded from `~/.config/cranium/tts.yaml`
  on each call, so edits take effect immediately without restart.
  """

  @behaviour Cranium.Backend.TTS

  @defaults %{"voice" => "af_exo", "speed" => 1.0}

  @impl true
  def synthesize(text, opts) do
    url = Keyword.get(opts, :url) || tts_url()
    format = Keyword.get(opts, :format, "mp3")

    prosody = load_prosody()
    voice = Keyword.get(opts, :voice) || prosody["voice"]
    speed = Keyword.get(opts, :speed) || prosody["speed"]

    payload = %{input: text, voice: voice, speed: speed, response_format: format}
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

  defp load_prosody do
    path = tts_config_path()

    case YamlElixir.read_from_file(path) do
      {:ok, config} when is_map(config) ->
        Map.merge(@defaults, config)

      _ ->
        @defaults
    end
  end

  defp tts_config_path do
    Application.get_env(:cranium, :tts_config_path) ||
      Path.join(
        System.get_env("XDG_CONFIG_HOME", Path.expand("~/.config")),
        "cranium/tts.yaml"
      )
  end

  defp tts_url do
    Application.get_env(:cranium, :backends)[:tts_url] ||
      raise "TTS_URL not configured — set TTS_URL env var"
  end
end
