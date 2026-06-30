defmodule Cranium.RoomSync.EventStream do
  @moduledoc """
  Resumable SSE event stream for room-level events.

  Protocol:
  1. Subscribe to conversation topic BEFORE reading from DB
  2. Catch up on historical events since the `since` cursor
  3. Enter live loop, deduping any events already sent during catchup
  4. 30s keepalive comments to prevent proxy/LB timeouts

  The subscribe-before-read ordering guarantees no events are lost
  between the DB read and the subscription starting. The dedup
  window handles the overlap (events that arrive via subscription
  during the DB read).

  ## Ephemeral events

  In addition to durable RoomEvents (persisted, replayable), the stream
  forwards ephemeral mid-turn events from the Agent:

  - `turn.delta` — text chunk during streaming
  - `turn.tool_use` — tool call started (name, input, id)
  - `turn.tool_result` — tool call completed (result, is_error)

  These use the same SSE envelope shape but carry `seq: null` to signal
  they are not replayable. Reconnecting clients recover mid-turn state
  from the enriched `active_turn` in the snapshot instead.
  """

  require Logger

  @keepalive_interval_ms 30_000

  @doc """
  Serve a resumable SSE event stream on `conn`.

  `since_seq` is the last seq the client saw (0 for fresh).
  All events with seq > since_seq will be delivered, then live events.
  """
  @spec serve(Plug.Conn.t(), String.t(), integer()) :: Plug.Conn.t()
  def serve(conn, room_id, since_seq) do
    # 1. Subscribe BEFORE DB read (gap-free invariant)
    Cranium.Events.subscribe({:conversation, room_id})

    # 2. Check cursor expiry — if client's cursor is older than
    #    the oldest available event, they must re-fetch the snapshot
    {:ok, oldest_seq} = Cranium.Store.oldest_room_event_seq(room_id)

    if oldest_seq != nil and since_seq > 0 and since_seq < oldest_seq do
      # Cursor expired — events between since_seq and oldest_seq are gone
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)
      |> send_cursor_expired(room_id)
    else
      # 3. Catch up from DB
      {:ok, catchup_events} = Cranium.Store.list_room_events(room_id, since_seq)

      # 4. Open chunked SSE response
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
        |> Plug.Conn.send_chunked(200)

      # 5. Send catchup events
      {conn, last_seq} =
        Enum.reduce(catchup_events, {conn, since_seq}, fn event, {conn, _seq} ->
          case send_durable_event(conn, event) do
            {:ok, conn} -> {conn, event.seq}
            {:error, _} -> throw({:client_gone, conn})
          end
        end)

      # 6. Enter live loop — dedup anything with seq <= last_seq
      schedule_keepalive()
      live_loop(conn, room_id, last_seq)
    end
  catch
    {:client_gone, conn} ->
      Logger.debug("Room event stream client disconnected during catchup",
        room_id: room_id
      )

      conn
  end

  defp live_loop(conn, room_id, last_seq) do
    receive do
      # --- Durable room events (persisted, replayable) ---

      {:room_event, %{seq: seq} = event} when seq > last_seq ->
        case send_durable_event(conn, event) do
          {:ok, conn} ->
            live_loop(conn, room_id, seq)

          {:error, _} ->
            Logger.debug("Room event stream client disconnected",
              room_id: room_id,
              last_seq: seq
            )

            conn
        end

      {:room_event, %{seq: seq}} when seq <= last_seq ->
        # Dedupe: already sent during catchup
        live_loop(conn, room_id, last_seq)

      # --- Ephemeral turn events (NOT persisted, live rendering only) ---

      {:chunk, _stream_id, text} when is_binary(text) ->
        case send_ephemeral_event(conn, room_id, "turn.delta", %{content: text}) do
          {:ok, conn} -> live_loop(conn, room_id, last_seq)
          {:error, _} -> conn
        end

      {:chunk, _stream_id, {:tool_use, tool_data}} ->
        payload = %{
          id: tool_data[:id] || tool_data["id"],
          name: tool_data[:name] || tool_data["name"],
          input: tool_data[:input] || tool_data["input"]
        }

        case send_ephemeral_event(conn, room_id, "turn.tool_use", payload) do
          {:ok, conn} -> live_loop(conn, room_id, last_seq)
          {:error, _} -> conn
        end

      {:chunk, _stream_id, {:tool_result, result_data}} ->
        payload = %{
          tool_use_id: result_data[:tool_use_id] || result_data["tool_use_id"],
          content: result_data[:content] || result_data["content"],
          is_error: result_data[:is_error] || result_data["is_error"] || false
        }

        case send_ephemeral_event(conn, room_id, "turn.tool_result", payload) do
          {:ok, conn} -> live_loop(conn, room_id, last_seq)
          {:error, _} -> conn
        end

      # --- Keepalive ---

      :keepalive ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            live_loop(conn, room_id, last_seq)

          {:error, _} ->
            conn
        end

      # Ignore other conversation-topic messages (markers, stream_start/end, etc.)
      _other ->
        live_loop(conn, room_id, last_seq)
    end
  end

  # Durable events carry their own seq as the SSE id
  defp send_durable_event(conn, event) do
    data = Jason.encode!(event)

    Plug.Conn.chunk(
      conn,
      "id: #{event.seq}\nevent: #{event.type}\ndata: #{data}\n\n"
    )
  end

  # Ephemeral events have seq: null and no SSE id (not replayable)
  defp send_ephemeral_event(conn, room_id, type, payload) do
    data =
      Jason.encode!(%{
        type: type,
        room_id: room_id,
        seq: nil,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        payload: payload
      })

    Plug.Conn.chunk(conn, "event: #{type}\ndata: #{data}\n\n")
  end

  # cursor_expired tells the client their cursor is too old — events have
  # been purged. They must re-fetch the snapshot to get current state.
  defp send_cursor_expired(conn, room_id) do
    data =
      Jason.encode!(%{
        type: "cursor_expired",
        room_id: room_id,
        seq: nil,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        payload: %{refresh: true}
      })

    case Plug.Conn.chunk(conn, "event: cursor_expired\ndata: #{data}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
  end
end
