defmodule Cranium.Transport.HTTP do
  @moduledoc """
  HTTP transport for cranium v2.

  Endpoints:
  - `POST /v1/submit` — accept input, create epoch, return stream_id
  - `GET /v1/streams/:id/manifest` — segment manifest with current status
  - `GET /v1/streams/:id/segments/:n/:rendition` — individual segment content
  - `GET /v1/conversations/:id` — conversation metadata (status, saturation, handoff lifecycle)
  - `POST /v1/input/start` — open a chunked audio take
  - `PUT /v1/input/:id/:seq` — append numbered audio chunk
  - `POST /v1/input/:id/done` — seal a take
  - `POST /v1/clear` — clear the active epoch

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
    origin = conn.body_params["origin"]
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
              "[Transcribed from audio]\n#{transcribed}"

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
      disposition: disposition,
      origin: origin
    }

    Logger.info("Submit: stream=#{stream_id} conversation=#{conversation_id} disposition=#{inspect(disposition)} text=#{inspect(String.slice(text || "", 0..80))}", transport: :http)

    # Check for commands before dispatching to inference
    case text do
      "!clear" ->
        Cranium.Epoch.clear(epoch_pid)
        Logger.info("Cleared epoch", conversation_id: conversation_id, transport: :http)
        Cranium.Manifest.complete(stream_id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"stream_id" => stream_id, "command" => "clear"}))

      "!cancel" ->
        result = Cranium.Epoch.cancel(conversation_id)
        Logger.info("Cancel result: #{inspect(result)}", conversation_id: conversation_id, transport: :http)
        Cranium.Manifest.complete(stream_id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"stream_id" => stream_id, "command" => "cancel"}))

      _ ->
        # Run inference asynchronously
        Task.start(fn ->
          case Cranium.Epoch.submit(epoch_pid, message) do
            {:ok, _result} ->
              Cranium.TTS.Cache.schedule_cleanup(stream_id)

            {:error, :cancelled} ->
              Logger.info("Submit cancelled: stream=#{stream_id}", transport: :http)
              Cranium.Manifest.cancel(stream_id)

            {:error, reason} ->
              Logger.error("Submit failed: stream=#{stream_id} reason=#{inspect(reason)}", transport: :http)
              Cranium.Manifest.complete(stream_id)
          end
        end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{"stream_id" => stream_id}))
    end
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
    origin = conn.body_params["origin"]
    disposition = parse_disposition(conn.body_params["disposition"])

    take_id = Cranium.Stage.new_stream_id()
    stream_id = Cranium.Stage.new_stream_id()

    :ok = Cranium.Input.TakeRegistry.open(take_id, stream_id, conversation_id, disposition, origin: origin)
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
            audio = File.read!(path)
            Logger.info("Chunk received: take=#{id} seq=#{seq_int} size=#{byte_size(audio)}", transport: :http)
            stt = Application.get_env(:cranium, :backends)[:stt] || Cranium.Backend.STT.Whisper

            case stt.transcribe(audio, []) do
              {:ok, text} ->
                Logger.info("Chunk STT: take=#{id} seq=#{seq_int} transcribed #{byte_size(audio)} bytes", transport: :http)

                case Cranium.Input.TakeRegistry.put_chunk(id, seq_int, text) do
                  {:ok, :buffered} ->
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(200, Jason.encode!(%{"status" => "buffered"}))

                  {:ok, :complete, result} ->
                    trigger_text_inference(result, id)

                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(200, Jason.encode!(%{"status" => "complete"}))

                  {:error, :not_found} ->
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(404, Jason.encode!(%{"error" => "take not found"}))

                  {:error, :already_complete} ->
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(409, Jason.encode!(%{"error" => "take already complete"}))
                end

              {:error, reason} ->
                Logger.error("Chunk STT failed: take=#{id} seq=#{seq_int} reason=#{inspect(reason)}", transport: :http)

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(502, Jason.encode!(%{"error" => "transcription failed"}))
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
            trigger_text_inference(result, id)

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

  get "/v1/conversations/:id" do
    conversation_id = id

    # Read epoch state from DB — doesn't touch the (potentially blocked) Epoch GenServer
    epoch_data =
      case Cranium.Store.get_epoch(conversation_id) do
        {:ok, epoch} -> epoch
        :not_found -> nil
      end

    # Check if a handoff is currently being generated (Registry auto-clears on Task exit)
    handoff_generating =
      Registry.lookup(Cranium.Epoch.Registry, {conversation_id, :handoff}) != []

    # Check if an Epoch process is alive for this conversation
    has_process =
      case Cranium.Epoch.lookup(conversation_id) do
        {:ok, _pid} -> true
        :not_found -> false
      end

    if epoch_data do
      body = %{
        "conversation_id" => conversation_id,
        "epoch_id" => epoch_data.id,
        "status" => epoch_data.status,
        "turn_count" => epoch_data.turn_count,
        "saturation" => epoch_data.saturation,
        "handoff_generating" => handoff_generating,
        "has_process" => has_process,
        "cc_session_id" => epoch_data.cc_session_id,
        "updated_at" => epoch_data.updated_at && DateTime.to_iso8601(epoch_data.updated_at)
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"error" => "conversation not found"}))
    end
  end

  post "/v1/clear" do
    conversation_id = conn.body_params["conversation_id"] || "default"

    case Cranium.Epoch.start_or_get(conversation_id) do
      {:ok, pid} ->
        Cranium.Epoch.clear(pid)
        Logger.info("Cleared epoch", conversation_id: conversation_id, transport: :http)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "cleared"}))

      {:error, reason} ->
        Logger.error("Failed to start epoch for clear: #{inspect(reason)}",
          conversation_id: conversation_id
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"error" => "failed to start epoch"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  defp trigger_text_inference(result, take_id) do
    Task.start(fn ->
      content_key = result.disposition |> List.first("text") |> String.to_atom()
      raw_text = Map.fetch!(result, content_key)
      text = if content_key == :audio, do: "[Transcribed from audio]\n#{raw_text}", else: raw_text
      Logger.info("Input complete: take=#{take_id} text=#{inspect(String.slice(text, 0..80))}", transport: :http)

      case Cranium.Epoch.start_or_get(result.conversation_id) do
        {:ok, epoch_pid} ->
          message = %{
            text: text,
            conversation_id: result.conversation_id,
            stream_id: result.stream_id,
            disposition: result.disposition,
            origin: result.origin
          }

          case Cranium.Epoch.submit(epoch_pid, message) do
            {:ok, _} ->
              Cranium.TTS.Cache.schedule_cleanup(result.stream_id)

            {:error, :cancelled} ->
              Logger.info("Input submit cancelled: take=#{take_id}", transport: :http)
              Cranium.Manifest.cancel(result.stream_id)

            {:error, reason} ->
              Logger.error("Input submit failed: take=#{take_id} reason=#{inspect(reason)}", transport: :http)
              Cranium.Manifest.complete(result.stream_id)
          end
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
