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
  plug Plug.Parsers, parsers: [:json, :multipart], json_decoder: Jason
  plug :dispatch

  post "/v1/submit" do
    conversation_id = conn.body_params["conversation_id"] || "default"
    system = conn.body_params["system"]
    disposition = parse_disposition(conn.body_params["disposition"])

    # Extract text — either directly or by transcribing audio
    text =
      case {conn.body_params["text"], conn.body_params["audio"]} do
        {text, _} when is_binary(text) and text != "" ->
          text

        {_, %Plug.Upload{path: path}} ->
          audio = File.read!(path)
          stt = Application.get_env(:cranium, :backends)[:stt] || Cranium.Backend.STT.Whisper

          case stt.transcribe(audio, []) do
            {:ok, transcribed} ->
              Logger.info("STT: transcribed #{byte_size(audio)} bytes", transport: :http)
              transcribed

            {:error, reason} ->
              Logger.error("STT failed: #{inspect(reason)}", transport: :http)
              nil
          end

        _ ->
          nil
      end

    # Get or start an epoch for this conversation
    epoch_pid =
      case Cranium.Epoch.start_or_get(conversation_id) do
        {:ok, pid} -> pid
      end

    # Generate a stream_id for manifest tracking
    stream_id = Cranium.Stage.new_stream_id()
    Cranium.Manifest.init_stream(stream_id, conversation_id, disposition: disposition)

    message = %{
      text: text,
      system: system,
      conversation_id: conversation_id,
      stream_id: stream_id,
      disposition: disposition
    }

    Logger.info("Submit: stream=#{stream_id} conversation=#{conversation_id} disposition=#{inspect(disposition)} text=#{inspect(String.slice(text || "", 0..80))}", transport: :http)

    # Run inference asynchronously — Egress handles manifest population
    # and TTS warming incrementally. Task just schedules cleanup.
    Task.start(fn ->
      case Cranium.Epoch.submit(epoch_pid, message) do
        {:ok, _result} ->
          Cranium.TTS.Cache.schedule_cleanup(stream_id)

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

  post "/v1/input/start" do
    conversation_id = conn.body_params["conversation_id"] || "default"
    disposition = parse_disposition(conn.body_params["disposition"])

    take_id = Cranium.Stage.new_stream_id()
    stream_id = Cranium.Stage.new_stream_id()

    :ok = Cranium.Input.TakeRegistry.open(take_id, stream_id, conversation_id, disposition)
    :ok = Cranium.Manifest.init_stream(stream_id, conversation_id, disposition: disposition)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"take_id" => take_id, "stream_id" => stream_id}))
  end

  put "/v1/input/:id/:seq" do
    case Integer.parse(seq) do
      {seq_int, ""} ->
        case conn.body_params["chunk"] do
          %Plug.Upload{path: path} ->
            data = File.read!(path)

            case Cranium.Input.TakeRegistry.put_chunk(id, seq_int, data) do
              {:ok, :buffered} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{"status" => "buffered"}))

              {:ok, :complete, result} ->
                trigger_audio_inference(result, id)

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{"status" => "complete"}))

              {:error, :not_found} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(404, Jason.encode!(%{"error" => "take not found"}))
            end

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{"error" => "missing chunk field"}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "invalid sequence number"}))
    end
  end

  post "/v1/input/:id/done" do
    case conn.body_params["last_seq"] do
      last_seq when is_integer(last_seq) ->
        case Cranium.Input.TakeRegistry.seal(id, last_seq) do
          {:ok, :complete, result} ->
            trigger_audio_inference(result, id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"missing" => []}))

          {:ok, :incomplete, missing} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"missing" => missing}))

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, Jason.encode!(%{"error" => "take not found"}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "missing or invalid last_seq"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  defp trigger_audio_inference(result, take_id) do
    Task.start(fn ->
      stt = Application.get_env(:cranium, :backends)[:stt] || Cranium.Backend.STT.Whisper

      case stt.transcribe(result.audio, []) do
        {:ok, text} ->
          Logger.info("Input STT: take=#{take_id} transcribed #{byte_size(result.audio)} bytes", transport: :http)

          case Cranium.Epoch.start_or_get(result.conversation_id) do
            {:ok, epoch_pid} ->
              stream_id = result.stream_id
              message = %{
                text: text,
                conversation_id: result.conversation_id,
                stream_id: stream_id,
                disposition: result.disposition
              }

              case Cranium.Epoch.submit(epoch_pid, message) do
                {:ok, _} -> Cranium.TTS.Cache.schedule_cleanup(stream_id)
                {:error, reason} ->
                  Logger.error("Input submit failed: take=#{take_id} reason=#{inspect(reason)}", transport: :http)
                  Cranium.Manifest.complete(stream_id)
              end
          end

        {:error, reason} ->
          Logger.error("Input STT failed: take=#{take_id} reason=#{inspect(reason)}", transport: :http)
      end
    end)
  end

  defp parse_disposition(list) when is_list(list), do: list
  defp parse_disposition(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> ["text"]
    end
  end
  defp parse_disposition(_), do: ["text"]

end
