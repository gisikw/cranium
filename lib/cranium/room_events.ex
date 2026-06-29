defmodule Cranium.RoomEvents do
  @moduledoc """
  Room event emission — persist to Store and broadcast on Events bus.

  This is the integration layer between existing mutation sites (PassReactor,
  TurnAssembler, Harness, HandoffWriter, clear_epoch) and the room_events
  table + event stream. Each `emit/3,4` call:

  1. Writes a durable RoomEvent row via `Store.emit_room_event/4`
  2. Broadcasts the event envelope on `Cranium.Events` for the room's
     conversation topic so live SSE consumers receive it immediately.

  Callers pass the event type and payload; seq assignment and event_id
  generation happen inside Store (transactional, per-room monotonic).
  """

  require Logger

  @doc """
  Emit a room event — persist + broadcast.

  Returns `{:ok, event_map}` or `{:error, reason}`.
  """
  @spec emit(String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def emit(room_id, type, payload, correlation_id \\ nil) do
    case Cranium.Store.emit_room_event(room_id, type, payload, correlation_id) do
      {:ok, event} ->
        Cranium.Events.broadcast(
          room_id,
          {:room_event, event}
        )

        Logger.debug("RoomEvent emitted",
          room_id: room_id,
          type: type,
          seq: event.seq
        )

        {:ok, event}

      {:error, reason} = err ->
        Logger.error("RoomEvent emission failed: #{inspect(reason)}",
          room_id: room_id,
          type: type
        )

        err
    end
  end

  # --- Convenience emitters for each event type ---

  @doc "A message was persisted (user or assistant)."
  def message_created(room_id, %{role: role} = attrs, correlation_id \\ nil) do
    payload = %{
      role: to_string(role),
      origin: attrs[:origin],
      epoch_id: attrs[:epoch_id]
    }

    # Include text preview for room summaries (truncated)
    payload =
      case attrs[:text] do
        t when is_binary(t) and t != "" ->
          Map.put(payload, :preview, String.slice(t, 0, 200))

        _ ->
          payload
      end

    emit(room_id, "message.created", payload, correlation_id)
  end

  @doc "Inference started for a turn."
  def turn_started(room_id, %{stream_id: stream_id, epoch_id: epoch_id}) do
    emit(room_id, "turn.started", %{
      stream_id: stream_id,
      epoch_id: epoch_id
    })
  end

  @doc "Inference completed successfully."
  def turn_completed(room_id, %{stream_id: stream_id, epoch_id: epoch_id} = attrs) do
    payload = %{
      stream_id: stream_id,
      epoch_id: epoch_id,
      turn_count: attrs[:turn_count],
      saturation: attrs[:saturation]
    }

    emit(room_id, "turn.completed", payload)
  end

  @doc "Inference was cancelled."
  def turn_cancelled(room_id, %{stream_id: stream_id, epoch_id: epoch_id}) do
    emit(room_id, "turn.cancelled", %{
      stream_id: stream_id,
      epoch_id: epoch_id
    })
  end

  @doc "Inference errored."
  def turn_errored(room_id, %{stream_id: stream_id, epoch_id: epoch_id}) do
    emit(room_id, "turn.errored", %{
      stream_id: stream_id,
      epoch_id: epoch_id
    })
  end

  @doc "Epoch was cleared (context reset)."
  def epoch_cleared(room_id, %{epoch_id: epoch_id} = attrs) do
    emit(room_id, "room.epoch.cleared", %{
      epoch_id: epoch_id,
      source: attrs[:source]
    })
  end

  @doc "Handoff generation completed."
  def handoff_completed(room_id, %{epoch_id: epoch_id}) do
    emit(room_id, "handoff.completed", %{
      epoch_id: epoch_id
    })
  end

  @doc "Saturation level updated."
  def saturation_updated(room_id, %{epoch_id: epoch_id, saturation: saturation}) do
    emit(room_id, "context.saturation.updated", %{
      epoch_id: epoch_id,
      saturation: saturation
    })
  end
end
