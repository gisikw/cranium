defmodule Cranium.Media.Transcoder.Transcriber do
  require Logger

  @max_retries 3
  @base_backoff_ms 2_000
  @recv_timeout 60_000

  def process(audio), do: process(audio, 0)

  defp process(audio, attempt) do
    req_opts = [
      form_multipart: [
        file: {audio, filename: "audio", content_type: "application/octet-stream"}
      ],
      receive_timeout: @recv_timeout
    ]

    case Req.post(stt_url(), req_opts) do
      {:ok, %{status: 200, body: %{"error" => error}}} when not is_nil(error) ->
        {:error, {:stt_error, error}}

      {:ok, %{status: 200, body: %{"text" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        maybe_retry(audio, attempt, {:http_error, status, body})

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{} = reason} ->
        maybe_retry(audio, attempt, reason)

      {:error, reason} ->
        maybe_retry(audio, attempt, reason)
    end
  end

  defp maybe_retry(audio, attempt, reason) when attempt < @max_retries do
    backoff = @base_backoff_ms * Integer.pow(2, attempt)

    Logger.warning(
      "Transcription attempt #{attempt + 1}/#{@max_retries + 1} failed: #{inspect(reason)}, " <>
        "retrying in #{backoff}ms"
    )

    Process.sleep(backoff)
    process(audio, attempt + 1)
  end

  defp maybe_retry(_audio, _attempt, reason) do
    {:error, reason}
  end

  defp stt_url do
    Application.get_env(:cranium, :backends)[:stt_url] || "https://stt.example.com/transcribe"
  end
end
