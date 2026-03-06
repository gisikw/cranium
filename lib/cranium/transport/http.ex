defmodule Cranium.Transport.HTTP do
  @moduledoc """
  HTTP transport for cranium v2.

  Three endpoints:
  - `POST /v1/submit` — accept input, create epoch, return stream_id
  - `GET /v1/streams/:id/manifest` — segment manifest with current status
  - `GET /v1/streams/:id/segments/:n/:rendition` — individual segment content

  Client loop: submit → poll manifest → consume new segments → repeat
  until `status: "complete"`.
  """

  use Plug.Router

  require Logger

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/v1/submit" do
    conversation_id = conn.body_params["conversation_id"] || "default"
    text = conn.body_params["text"]
    system = conn.body_params["system"]

    message = %{
      text: text,
      system: system,
      conversation_id: conversation_id
    }

    # Get or start an epoch for this conversation
    epoch_pid =
      case Cranium.Epoch.start_or_get(conversation_id) do
        {:ok, pid} -> pid
      end

    # Generate a stream_id for manifest tracking
    stream_id = Cranium.Stage.new_stream_id()
    Cranium.Manifest.init_stream(stream_id, conversation_id)

    Logger.info("Submit: stream=#{stream_id} conversation=#{conversation_id} text=#{inspect(String.slice(text || "", 0..80))}", transport: :http)

    # Run inference asynchronously — client polls the manifest
    Task.start(fn ->
      case Cranium.Epoch.submit(epoch_pid, message) do
        {:ok, result} ->
          output = result.output || ""
          Cranium.Manifest.add_utterance(stream_id, 0, output)
          Cranium.Manifest.complete(stream_id)
          Cranium.TTS.Cache.schedule_cleanup(stream_id)
          Logger.info("Complete: stream=#{stream_id} segments=1 output=#{inspect(String.slice(output, 0..80))}", transport: :http)

        {:error, reason} ->
          Logger.error("Submit failed: stream=#{stream_id} reason=#{inspect(reason)}", transport: :http)
          Cranium.Manifest.complete(stream_id)
      end
    end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, Jason.encode!(%{"stream_id" => stream_id}))
  end

  get "/v1/streams/:id/manifest" do
    case Cranium.Manifest.get(id) do
      {:ok, manifest} ->
        Logger.debug("Manifest poll: stream=#{id} status=#{manifest["status"]} segments=#{length(manifest["segments"])}", transport: :http)
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(manifest))

      :not_found ->
        Logger.debug("Manifest poll: stream=#{id} not_found", transport: :http)
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "stream not found"}))
    end
  end

  get "/v1/streams/:id/segments/:n/text" do
    index = String.to_integer(n)

    case Cranium.Manifest.get_segment_text(id, index) do
      {:ok, text} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, text)

      :not_found ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "segment not found"}))
    end
  end

  get "/v1/streams/:id/segments/:n/audio" do
    index = String.to_integer(n)

    case Cranium.TTS.Cache.get(id, index) do
      {:ok, audio} ->
        conn
        |> put_resp_content_type("audio/mpeg")
        |> send_resp(200, audio)

      {:error, :segment_not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "segment not found"}))

      {:error, reason} ->
        Logger.error("TTS synthesis failed: stream=#{id} segment=#{index} reason=#{inspect(reason)}", transport: :http)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{"error" => "TTS synthesis failed"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end
end
