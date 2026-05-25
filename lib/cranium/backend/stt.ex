defmodule Cranium.Backend.STT do
  @moduledoc """
  Behaviour for Speech-to-Text backends.

  Implementations convert audio binary data to text. Current implementation
  is Whisper (OpenAI-compatible STT endpoint).
  """

  @doc """
  Transcribe audio to text.

  `audio` is the raw audio binary.
  `opts` may include `:language` (hint for Whisper), `:url` (backend override).
  """
  @callback transcribe(audio :: binary(), opts :: keyword()) ::
              {:ok, text :: String.t()} | {:error, term()}
end

defmodule Cranium.Backend.STT.Whisper do
  @moduledoc """
  STT backend using Whisper (OpenAI-compatible).

  Sends audio to the configured STT endpoint via multipart POST.
  """

  @behaviour Cranium.Backend.STT

  @impl true
  def transcribe(audio, opts) do
    url = Keyword.get(opts, :url) || stt_url()
    language = Keyword.get(opts, :language)
    plug = Keyword.get(opts, :plug)

    form_fields =
      [file: {audio, filename: "audio", content_type: "application/octet-stream"}] ++
        if(language, do: [language: language], else: [])

    req_opts =
      [form_multipart: form_fields, connect_options: [timeout: 10_000], receive_timeout: 300_000] ++
        if(plug, do: [plug: plug], else: [])

    case Req.post(url, req_opts) do
      {:ok, %{status: 200, body: %{"error" => error}}} when not is_nil(error) ->
        {:error, {:stt_error, error}}

      {:ok, %{status: 200, body: %{"text" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stt_url do
    Application.get_env(:cranium, :backends)[:stt_url] ||
      raise "STT_URL not configured — set STT_URL env var"
  end
end
