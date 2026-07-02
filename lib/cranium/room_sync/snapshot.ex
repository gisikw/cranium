defmodule Cranium.RoomSync.Snapshot do
  @moduledoc """
  Composes a room snapshot for the sync API.

  A snapshot contains:
  - Room metadata (id, title)
  - Room state (epoch info, active turn, saturation)
  - Recent transcript (projected as TranscriptMessage)
  - Cursor (latest event seq for gap-free sync)
  - has_more flag (whether older messages exist)

  The cursor is fetched AFTER assembling state to guarantee the
  SnapshotCursorGapFree invariant: any event with seq > cursor
  will be delivered via the event stream.
  """

  alias Cranium.RoomSync.TranscriptMessage

  @default_message_count 50

  @doc """
  Build a snapshot for the given room.

  Returns `{:ok, snapshot_map}` or `{:error, reason}`.
  """
  @spec build(String.t()) :: {:ok, map()} | {:error, :db_error}
  def build(room_id) do
    # 1. Ensure epoch exists (get or create)
    with {:ok, epoch_ctx} <- Cranium.Store.get_or_create_epoch(room_id),
         # 2. Fetch recent messages as structs for TranscriptMessage projection
         {:ok, %{messages: message_structs, has_more: has_more}} <-
           Cranium.Store.recent_message_structs(room_id, limit: @default_message_count) do
      # 3. Project messages to TranscriptMessage shape
      transcript = TranscriptMessage.project_many(message_structs)

      # 4. Detect active turn via Registry
      active_turn = detect_active_turn(room_id)

      # 5. Compose room state
      state = %{
        epoch_id: epoch_ctx.epoch_id,
        saturation: epoch_ctx.saturation || 0.0,
        turn_count: epoch_ctx.turn_count || 0,
        handoff_generating: handoff_generating?(room_id),
        active_turn: active_turn,
        profile: epoch_ctx[:profile]
      }

      # 6. Fetch cursor AFTER state assembly (SnapshotCursorGapFree invariant)
      cursor_seq =
        case Cranium.Store.latest_room_event_seq(room_id) do
          {:ok, seq} -> seq
          {:error, _} -> 0
        end

      snapshot = %{
        room: %{
          id: room_id,
          title: room_id
        },
        state: state,
        recent_transcript: transcript,
        cursor: %{
          room_id: room_id,
          seq: cursor_seq
        },
        has_more: has_more
      }

      {:ok, snapshot}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Detect if inference is currently running for this room,
  # and if so, return enriched turn state from the Registry.
  defp detect_active_turn(room_id) do
    registry = Cranium.Inference.ConversationRegistry

    case Registry.lookup(registry, {room_id, :agent}) do
      [{_pid, _agent_pid}] ->
        # Agent is running — read accumulated turn state
        turn_state =
          case Registry.lookup(registry, {room_id, :turn_state}) do
            [{_pid, ts}] -> ts
            [] -> %{}
          end

        %{
          stream_id: turn_state[:stream_id],
          conversation_id: room_id,
          started_at:
            Cranium.RoomSync.Timestamp.iso8601(turn_state[:started_at] || DateTime.utc_now()),
          accumulated_text: turn_state[:accumulated_text],
          accumulated_parts: turn_state[:accumulated_parts],
          pending_tool_calls: turn_state[:pending_tool_calls]
        }

      [] ->
        nil
    end
  end

  defp handoff_generating?(room_id) do
    registry = Cranium.Inference.ConversationRegistry
    Registry.lookup(registry, {room_id, :handoff}) != []
  end
end
