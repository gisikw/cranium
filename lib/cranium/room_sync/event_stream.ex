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

    # 2. Catch up from DB
    {:ok, catchup_events} = Cranium.Store.list_room_events(room_id, since_seq)

    # 3. Open chunked SSE response
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    # 4. Send catchup events
    {conn, last_seq} =
      Enum.reduce(catchup_events, {conn, since_seq}, fn event, {conn, _seq} ->
        case send_event(conn, event) do
          {:ok, conn} -> {conn, event.seq}
          {:error, _} -> throw({:client_gone, conn})
        end
      end)

    # 5. Enter live loop — dedup anything with seq <= last_seq
    schedule_keepalive()
    live_loop(conn, room_id, last_seq)
  catch
    {:client_gone, conn} ->
      Logger.debug("Room event stream client disconnected during catchup",
        room_id: room_id
      )

      conn
  end

  defp live_loop(conn, room_id, last_seq) do
    receive do
      {:room_event, %{seq: seq} = event} when seq > last_seq ->
        case send_event(conn, event) do
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

      :keepalive ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            live_loop(conn, room_id, last_seq)

          {:error, _} ->
            conn
        end

      # Ignore other conversation-topic messages (chunks, stream events, etc.)
      _other ->
        live_loop(conn, room_id, last_seq)
    end
  end

  defp send_event(conn, event) do
    data = Jason.encode!(event)

    Plug.Conn.chunk(
      conn,
      "id: #{event.seq}\nevent: #{event.type}\ndata: #{data}\n\n"
    )
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
  end
end
