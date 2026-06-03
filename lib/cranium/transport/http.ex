defmodule Cranium.Transport.HTTP do
  @moduledoc """
  HTTP transport for cranium.

  Endpoints:
  - `POST /v1/submit` — accept input, create epoch, return stream_id
  - `GET /v1/streams/:id/events` — per-stream SSE (single pass)
  - `GET /v1/streams/:id/manifest` — segment manifest with current status
  - `GET /v1/streams/:id/segments/:n/:rendition` — individual segment content
  - `GET /v1/rooms` — list available rooms [{id, name, description}]
  - `GET /v1/conversations/:id` — conversation metadata (status, saturation, handoff lifecycle)
  - `GET /v1/conversations/:id/events` — conversation-level SSE (all passes)
  - `GET /v1/events` — global SSE firehose (all conversations)
  - `POST /v1/input/start` — open a chunked audio take
  - `PUT /v1/input/:id/:seq` — append numbered audio chunk
  - `POST /v1/input/:id/done` — seal a take
  - `POST /v1/clear` — clear the active epoch

  Client loop: submit → poll manifest → consume new segments → repeat
  until `status: "complete"`.
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json, :multipart], json_decoder: Jason)
  plug(:dispatch)

  post "/v1/submit" do
    drain_submit(conn)
  end

  # Extracted so drain guard can use early return
  defp drain_submit(conn) do
    if Cranium.Drain.draining?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "server is shutting down"}))
    else
      do_submit(conn)
    end
  end

  defp do_submit(conn) do
    conversation_id = conn.body_params["conversation_id"] || "default"
    text = conn.body_params["text"]
    origin = conn.body_params["origin"]

    # Commands are synchronous — no stream, no manifest, no inference pass
    case text do
      "!clear" <> rest ->
        continuation = String.trim(rest)
        continuation = if continuation == "", do: nil, else: continuation

        Cranium.clear_epoch(conversation_id,
          source: origin || "submit",
          continuation: continuation
        )

        Logger.info("Cleared epoch",
          conversation_id: conversation_id,
          transport: :http,
          has_continuation: continuation != nil
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"command" => "clear"}))

      "!cancel" ->
        result = Cranium.cancel(conversation_id)
        Logger.info("Cancel result: #{inspect(result)}",
          conversation_id: conversation_id, transport: :http)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"command" => "cancel"}))

      _ ->
        do_submit_pass(conn)
    end
  end

  defp do_submit_pass(conn) do
    conversation_id = conn.body_params["conversation_id"] || "default"
    system = conn.body_params["system"]
    origin = conn.body_params["origin"]
    disposition = parse_disposition(conn.body_params["disposition"])
    model = conn.body_params["model"]
    profile = conn.body_params["profile"]
    ephemeral = conn.body_params["ephemeral"] == true

    stream_id = Cranium.Stage.new_stream_id()
    Cranium.Transport.Manifest.init_stream(stream_id, conversation_id, disposition: disposition)

    text = conn.body_params["text"]
    audio = conn.body_params["audio"]

    pass_id = Cranium.Stage.new_stream_id()

    header = %Cranium.Messages.PassHeader{
      pass_id: pass_id,
      conversation_id: conversation_id,
      stream_id: stream_id,
      system: system,
      origin: origin,
      model: model,
      profile: profile,
      ephemeral: ephemeral,
      disposition: disposition
    }

    cond do
      is_binary(text) and text != "" ->
        Logger.info(
          "Submit: stream=#{stream_id} conversation=#{conversation_id} disposition=#{inspect(disposition)} text=#{inspect(String.slice(text, 0..80))}",
          transport: :http
        )

        # Ensure per-conversation TurnAssembler exists before broadcasting
        Cranium.Inference.Conversation.start_or_get(conversation_id)

        Cranium.Events.broadcast({:pass_header, header})
        Cranium.Events.broadcast({:text_input, %Cranium.Messages.TextInput{pass_id: header.pass_id, text: text}})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{"stream_id" => stream_id}))

      match?(%Plug.Upload{}, audio) ->
        audio_bytes = File.read!(audio.path)

        Logger.info(
          "Submit (audio): stream=#{stream_id} conversation=#{conversation_id} size=#{byte_size(audio_bytes)}",
          transport: :http
        )

        # Same ID as pass_id — Media calls it take_id, Inference calls it pass_id
        segment = %Cranium.Messages.Segment{
          direction: :inbound,
          audio: audio_bytes,
          take_id: pass_id
        }

        header = %{header | take_id: pass_id}

        # Ensure per-conversation TurnAssembler exists before broadcasting
        Cranium.Inference.Conversation.start_or_get(conversation_id)

        Cranium.Events.broadcast({:pass_header, header})
        Cranium.Events.broadcast({:segment_received, segment})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{"stream_id" => stream_id}))

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "missing text or audio"}))
    end
  end

  get "/v1/streams/:id/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Subscribe before checking state to avoid missing events in the gap
    Cranium.Events.subscribe({:stream_raw, id})

    # Check if stream already completed (late connect)
    case Cranium.Transport.Manifest.get(id) do
      {:ok, %{"status" => "complete"}} ->
        send_manifest_as_events(conn, id)

      {:ok, %{"status" => "cancelled"}} ->
        chunk(conn, sse_event("stream_end", %{stream_id: id, reason: "cancelled"}))
        conn

      _ ->
        # Stream in progress or not yet started — enter live loop
        sse_loop(conn, id, nil)
    end
  end

  get "/v1/conversations/:id/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    Cranium.Events.subscribe({:conversation, id})
    multi_stream_sse_loop(conn, %{})
  end

  get "/v1/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Send current service status immediately so clients that connect
    # after startup (the common case) don't miss the service_ready event.
    version = Application.spec(:cranium, :vsn) |> to_string()
    status_event = if Cranium.Drain.draining?(),
      do: sse_event("service_draining", %{reason: "reconnect", version: version, stream_id: "", conversation_id: ""}),
      else: sse_event("service_ready", %{version: version, stream_id: "", conversation_id: ""})
    {:ok, conn} = chunk(conn, status_event)

    Cranium.Events.subscribe()
    multi_stream_sse_loop(conn, %{})
  end

  get "/v1/streams/:id/manifest" do
    case Cranium.Transport.Manifest.get(id) do
      {:ok, manifest} ->
        Logger.debug(
          "Manifest poll: stream=#{id} status=#{manifest["status"]} segments=#{length(manifest["segments"])}",
          transport: :http
        )

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

    case Cranium.Transport.Manifest.get_segment_text(id, index) do
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

    case Cranium.Media.TTS.Cache.get(id, index) do
      {:ok, audio} ->
        conn
        |> put_resp_content_type("audio/mpeg")
        |> send_resp(200, audio)

      {:error, :segment_not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "segment not found"}))

      {:error, reason} ->
        Logger.error(
          "TTS synthesis failed: stream=#{id} segment=#{index} reason=#{inspect(reason)}",
          transport: :http
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{"error" => "TTS synthesis failed"}))
    end
  end

  post "/v1/input/start" do
    conversation_id = conn.body_params["conversation_id"] || "default"
    origin = conn.body_params["origin"]
    profile = conn.body_params["profile"]
    disposition = parse_disposition(conn.body_params["disposition"])

    take_id = Cranium.Stage.new_stream_id()
    stream_id = Cranium.Stage.new_stream_id()

    :ok =
      Cranium.Transport.SegmentRegistry.open(take_id, stream_id, conversation_id, disposition,
        origin: origin
      )

    :ok = Cranium.Transport.Manifest.init_stream(stream_id, conversation_id, disposition: disposition)

    # Bridge: emit PassHeader so TurnAssembler can correlate chunked takes
    header = %Cranium.Messages.PassHeader{
      pass_id: take_id,
      conversation_id: conversation_id,
      stream_id: stream_id,
      take_id: take_id,
      disposition: disposition,
      origin: origin,
      profile: profile
    }

    # Ensure per-conversation TurnAssembler exists before broadcasting
    Cranium.Inference.Conversation.start_or_get(conversation_id)

    Cranium.Events.broadcast({:pass_header, header})

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

            Logger.info("Chunk received: take=#{id} seq=#{seq_int} size=#{byte_size(audio)}",
              transport: :http
            )

            segment = %Cranium.Messages.Segment{
              direction: :inbound,
              audio: audio,
              take_id: id,
              seq: seq_int
            }

            Cranium.Events.broadcast({:segment_received, segment})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(202, Jason.encode!(%{"status" => "accepted"}))

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
        # Broadcast seal for TakeCollector (completion dispatch now via actors)
        Cranium.Events.broadcast({:take_sealed, id, last_seq})

        case Cranium.Transport.SegmentRegistry.seal(id, last_seq) do
          {:ok, :complete, _result} ->
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
      Registry.lookup(Cranium.Inference.ConversationRegistry, {conversation_id, :handoff}) != []

    # Check if a per-conversation supervisor is alive
    has_process =
      case Cranium.Inference.Conversation.lookup(conversation_id) do
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

  get "/v1/conversations/:id/messages" do
    params = URI.decode_query(conn.query_string)

    limit =
      case params["limit"] do
        nil -> 50
        str -> str |> String.to_integer() |> min(200) |> max(1)
      end

    after_ts =
      case params["after"] do
        nil ->
          nil

        str ->
          case DateTime.from_iso8601(str) do
            {:ok, dt, _offset} -> dt
            _ -> :invalid
          end
      end

    if after_ts == :invalid do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{"error" => "invalid 'after' timestamp"}))
    else
      opts = [limit: limit] ++ if(after_ts, do: [after: after_ts], else: [])

      case Cranium.Store.list_messages(id, opts) do
        {:ok, result} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(result))

        {:error, _} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(%{"error" => "database error"}))
      end
    end
  end

  post "/v1/clear" do
    conversation_id = conn.body_params["conversation_id"] || "default"
    continuation = conn.body_params["continuation"]

    Cranium.clear_epoch(conversation_id, source: "api", continuation: continuation)
    Logger.info("Cleared epoch", conversation_id: conversation_id, transport: :http)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"status" => "cleared"}))
  end

  get "/v1/rooms" do
    excluded = Application.get_env(:cranium, :excluded_rooms, [])
    rooms = Cranium.Inference.Landscape.list_rooms(exclude: excluded)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(rooms))
  end

  # --- OpenAI-compatible endpoints ---

  post "/v1/chat/completions" do
    Cranium.Transport.OpenAI.chat_completions(conn)
  end

  get "/v1/models" do
    Cranium.Transport.OpenAI.models(conn)
  end

  post "/v1/audio/speech" do
    Cranium.Transport.Audio.speech(conn)
  end

  post "/v1/audio/transcriptions" do
    Cranium.Transport.Audio.transcriptions(conn)
  end

  get "/health" do
    if Cranium.Drain.draining?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"status" => "draining"}))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"status" => "ok"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  # --- SSE helpers ---

  defp sse_loop(conn, stream_id, conversation_id) do
    receive do
      {:stream_start, ^stream_id, metadata} ->
        dispatch = Map.get(metadata, :dispatch)
        conv_id = metadata[:conversation_id]

        data = %{
          stream_id: stream_id,
          conversation_id: conv_id,
          harness: dispatch && dispatch.harness,
          model: dispatch && dispatch.model,
          renditions: dispatch && dispatch.renditions
        }

        {:ok, conn} = chunk(conn, sse_event("stream_start", data))
        sse_loop(conn, stream_id, conv_id)

      {:chunk, ^stream_id, text} when is_binary(text) ->
        {:ok, conn} = chunk(conn, sse_event("chunk", %{stream_id: stream_id, conversation_id: conversation_id, content: text}))
        sse_loop(conn, stream_id, conversation_id)

      {:chunk, ^stream_id, {:marker, marker}} ->
        {:ok, conn} =
          chunk(
            conn,
            sse_event("cue", %{stream_id: stream_id, conversation_id: conversation_id, cue_type: "marker", data: marker})
          )

        sse_loop(conn, stream_id, conversation_id)

      {:chunk, ^stream_id, {:tool_use, data}} ->
        {:ok, conn} =
          chunk(conn, sse_event("tool_use", %{stream_id: stream_id, conversation_id: conversation_id, data: data}))

        sse_loop(conn, stream_id, conversation_id)

      {:chunk, ^stream_id, {:tool_result, data}} ->
        {:ok, conn} =
          chunk(conn, sse_event("tool_result", %{stream_id: stream_id, conversation_id: conversation_id, data: data}))

        sse_loop(conn, stream_id, conversation_id)

      {:stream_end, ^stream_id} ->
        chunk(conn, sse_event("stream_end", %{stream_id: stream_id, conversation_id: conversation_id}))
        conn
    after
      30_000 ->
        # SSE keepalive comment (prevents proxy/LB timeouts)
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, stream_id, conversation_id)
          {:error, _} -> conn
        end
    end
  end

  # Long-lived SSE loop for conversation-level and global firehose endpoints.
  # Unlike sse_loop/2, this does not exit on stream_end — it survives across
  # multiple passes, relaying events from any stream that matches the
  # registered topic.
  defp multi_stream_sse_loop(conn, streams) do
    receive do
      {:stream_start, stream_id, metadata} ->
        dispatch = Map.get(metadata, :dispatch)
        conv_id = metadata[:conversation_id]

        data = %{
          stream_id: stream_id,
          conversation_id: conv_id,
          harness: dispatch && dispatch.harness,
          model: dispatch && dispatch.model,
          renditions: dispatch && dispatch.renditions
        }

        streams = Map.put(streams, stream_id, conv_id)

        case chunk(conn, sse_event("stream_start", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:chunk, stream_id, text} when is_binary(text) ->
        conv_id = Map.get(streams, stream_id)
        case chunk(conn, sse_event("chunk", %{stream_id: stream_id, conversation_id: conv_id, content: text})) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:chunk, stream_id, {:marker, marker}} ->
        conv_id = Map.get(streams, stream_id)
        case chunk(
               conn,
               sse_event("cue", %{stream_id: stream_id, conversation_id: conv_id, cue_type: "marker", data: marker})
             ) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:chunk, stream_id, {:tool_use, data}} ->
        conv_id = Map.get(streams, stream_id)
        case chunk(conn, sse_event("tool_use", %{stream_id: stream_id, conversation_id: conv_id, data: data})) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:chunk, stream_id, {:tool_result, data}} ->
        conv_id = Map.get(streams, stream_id)
        case chunk(conn, sse_event("tool_result", %{stream_id: stream_id, conversation_id: conv_id, data: data})) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:stream_end, stream_id} ->
        conv_id = Map.get(streams, stream_id)
        streams = Map.delete(streams, stream_id)
        case chunk(conn, sse_event("stream_end", %{stream_id: stream_id, conversation_id: conv_id})) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      # -- Lifecycle events --

      {:message_received, conversation_id, meta} ->
        data = Map.put(meta, :conversation_id, conversation_id)

        case chunk(conn, sse_event("message_received", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:pass_complete, conversation_id, stream_id, meta} ->
        # Silent passes (e.g. orientation) are persisted but not broadcast to clients.
        if meta[:silent] do
          multi_stream_sse_loop(conn, streams)
        else
          data = meta |> Map.put(:stream_id, stream_id) |> Map.put(:conversation_id, conversation_id)

          case chunk(conn, sse_event("pass_complete", data)) do
            {:ok, conn} -> multi_stream_sse_loop(conn, streams)
            {:error, _} -> conn
          end
        end

      {:epoch_started, conversation_id, meta} ->
        data = Map.put(meta, :conversation_id, conversation_id)

        case chunk(conn, sse_event("epoch_started", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:epoch_cleared, conversation_id, meta} ->
        data = Map.put(meta, :conversation_id, conversation_id)

        case chunk(conn, sse_event("epoch_cleared", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:handoff_complete, conversation_id, meta} ->
        data = Map.put(meta, :conversation_id, conversation_id)

        case chunk(conn, sse_event("handoff_complete", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      # -- Service lifecycle events --

      {:service_draining, meta} ->
        data = meta |> Map.put(:stream_id, "") |> Map.put(:conversation_id, "")

        case chunk(conn, sse_event("service_draining", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end

      {:service_ready, meta} ->
        data = meta |> Map.put(:stream_id, "") |> Map.put(:conversation_id, "")

        case chunk(conn, sse_event("service_ready", data)) do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> multi_stream_sse_loop(conn, streams)
          {:error, _} -> conn
        end
    end
  end

  defp send_manifest_as_events(conn, stream_id) do
    {:ok, manifest} = Cranium.Transport.Manifest.get(stream_id)

    conn =
      Enum.reduce(manifest["segments"], conn, fn seg, conn ->
        event_type = if seg["type"] == "utterance", do: "chunk", else: "cue"
        {:ok, conn} = chunk(conn, sse_event(event_type, seg))
        conn
      end)

    chunk(conn, sse_event("stream_end", %{stream_id: stream_id}))
    conn
  end

  defp sse_event(event_type, data) do
    "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
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
