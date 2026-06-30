defmodule Cranium.RoomSync.RoomList do
  @moduledoc """
  Enriches the Landscape room list with sync-relevant fields:
  latest_message_preview, latest_message_at, and has_active_turn.

  Queries the messages table for latest non-orientation messages
  and checks the ConversationRegistry for active inference.
  """

  import Ecto.Query

  alias Cranium.Store.Message
  alias Cranium.Store.Repo

  @preview_max_length 120

  @doc """
  Enrich a list of Landscape room maps with sync fields.

  Input: list of `%{id: room_id, name: ..., description: ..., last_activity_at: ...}`
  Output: list of RoomSummary-shaped maps
  """
  @spec enrich([map()]) :: [map()]
  def enrich(rooms) when is_list(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    # Batch fetch latest message per room
    latest_messages = fetch_latest_messages(room_ids)

    # Check active turns via Registry
    active_turns = detect_active_turns(room_ids)

    Enum.map(rooms, fn room ->
      latest = Map.get(latest_messages, room.id)

      %{
        id: room.id,
        name: room[:name] || room.id,
        description: room[:description],
        last_activity_at: room[:last_activity_at],
        latest_message_preview: preview_from_message(latest),
        latest_message_at: if(latest, do: latest.inserted_at),
        has_active_turn: MapSet.member?(active_turns, room.id),
        unread: false
      }
    end)
  end

  # Fetch the latest non-orientation message per room in a single query.
  # Uses a window function to rank messages per conversation_id.
  defp fetch_latest_messages(room_ids) when room_ids == [], do: %{}

  defp fetch_latest_messages(room_ids) do
    ranked =
      from(m in Message,
        where: m.conversation_id in ^room_ids,
        where: m.origin != "orientation" or is_nil(m.origin),
        select: %{
          conversation_id: m.conversation_id,
          content: m.content,
          role: m.role,
          inserted_at: m.inserted_at,
          rank: over(row_number(), partition_by: m.conversation_id, order_by: [desc: m.inserted_at, desc: m.id])
        }
      )

    from(r in subquery(ranked), where: r.rank == 1)
    |> Repo.all()
    |> Map.new(& {&1.conversation_id, &1})
  rescue
    # Defensive: if Repo isn't available (test without full supervision), return empty
    _ -> %{}
  end

  defp detect_active_turns(room_ids) do
    registry = Cranium.Inference.ConversationRegistry

    room_ids
    |> Enum.filter(fn room_id ->
      case Registry.lookup(registry, {room_id, :agent}) do
        [{_pid, _}] -> true
        _ -> false
      end
    end)
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  defp preview_from_message(nil), do: nil

  defp preview_from_message(%{content: content, role: role}) do
    text = Cranium.Store.extract_text(content)

    case text do
      "" -> nil
      t ->
        preview = String.slice(t, 0, @preview_max_length)
        prefix = if role == "user", do: "", else: ""
        truncated = if String.length(t) > @preview_max_length, do: "…", else: ""
        prefix <> preview <> truncated
    end
  end
end
