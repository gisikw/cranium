defmodule Cranium.Media.Transcoder.Transcriber do

  def process(audio) do
    req_opts = [
      form_multipart: [
        file: {audio, filename: "audio", content_type: "application/octet-stream"}
      ]
    ]

    case Req.post(stt_url(), req_opts) do
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
    Application.get_env(:cranium, :backends)[:stt_url] || "https://stt.example.com/transcribe"
  end
end
