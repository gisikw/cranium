defmodule Cranium.RoomSync.TranscriptMessage do
  @moduledoc """
  Projects stored Message rows into the TranscriptMessage shape defined
  by the room-sync spec.

  Each message's `content` (a list of Anthropic-shaped content blocks) is
  mapped to a typed `parts` list with stable IDs. A convenience `text`
  field concatenates all text-type parts.

  ## Part types

  - `text`         — `%{id, type: "text", text: String}`
  - `tool_call`    — `%{id, type: "tool_call", tool: String, input: Map, status, summary?}`
  - `tool_result`  — `%{id, type: "tool_result", tool_use_id: String, content: String, is_error: bool}`
  - `image`        — `%{id, type: "image", media_type: String, source: String}`
  - `status`       — `%{id, type: "status", text: String}`

  Part IDs are deterministic: `{message_id}:{index}` so the same content
  block always produces the same part ID regardless of whether it arrives
  via live event or historical transcript.
  """

  alias Cranium.Store.Message

  @type part :: map()
  @type t :: map()

  @doc """
  Project a Store.Message struct into a TranscriptMessage map.

  Options:
    - `:tool_results` — map of tool_use_id => result block, used to
      populate tool_call status/summary fields (default: %{})
  """
  @spec project(Message.t(), keyword()) :: t()
  def project(%Message{} = m, opts \\ []) do
    tool_results = Keyword.get(opts, :tool_results, %{})
    parts = content_to_parts(m.id, m.content, tool_results)
    text = extract_text(parts)

    base = %{
      id: m.id,
      room_id: m.conversation_id,
      role: m.role,
      parts: parts,
      text: text,
      origin: m.origin,
      created_at: m.inserted_at,
      epoch_id: m.epoch_id,
      parent_id: m.parent_id
    }

    base = if m.provenance, do: Map.put(base, :provenance, m.provenance), else: base
    base = if m.usage, do: Map.put(base, :usage, m.usage), else: base
    base
  end

  @doc """
  Project a list of Message structs into TranscriptMessage maps.

  Automatically resolves tool_result blocks so that tool_call parts
  get accurate status fields.
  """
  @spec project_many([Message.t()]) :: [t()]
  def project_many(messages) do
    # Build a map of tool_use_id => tool_result content block from
    # all tool_result user messages in the batch.
    tool_results =
      messages
      |> Enum.flat_map(fn m ->
        (m.content || [])
        |> Enum.filter(&is_tool_result?/1)
        |> Enum.map(fn block ->
          id = block["tool_use_id"] || block[:tool_use_id]
          {id, block}
        end)
        |> Enum.reject(fn {id, _} -> is_nil(id) end)
      end)
      |> Map.new()

    # Exclude tool_result-only user messages from the projection —
    # their content is folded into the preceding tool_call's status.
    messages
    |> Enum.reject(&tool_result_only?/1)
    |> Enum.reject(&orientation_origin?/1)
    |> Enum.map(&project(&1, tool_results: tool_results))
  end

  # --- Content block → MessagePart mapping ---

  defp content_to_parts(message_id, blocks, tool_results) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, idx} ->
      part_id = "#{message_id}:#{idx}"
      block_to_part(part_id, block, tool_results)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp content_to_parts(message_id, text, _tool_results) when is_binary(text) do
    [%{id: "#{message_id}:0", type: "text", text: text}]
  end

  defp content_to_parts(_message_id, _other, _tool_results), do: []

  defp block_to_part(part_id, block, tool_results) do
    type = block["type"] || block[:type]

    case type do
      "text" ->
        %{
          id: part_id,
          type: "text",
          text: block["text"] || block[:text] || ""
        }

      "tool_use" ->
        tool_use_id = block["id"] || block[:id] || block["tool_use_id"] || block[:tool_use_id]
        tool_name = block["name"] || block[:name] || block["tool_name"] || block[:tool_name]
        input = block["input"] || block[:input]
        result = Map.get(tool_results, tool_use_id)

        status = tool_call_status(result)

        part = %{
          id: part_id,
          type: "tool_call",
          tool: tool_name,
          input: input,
          status: status
        }

        # Add error summary if the tool errored
        case result do
          %{"is_error" => true} ->
            content = to_string(result["content"] || "")
            Map.put(part, :summary, String.slice(content, 0, 200))

          %{is_error: true} ->
            content = to_string(result[:content] || "")
            Map.put(part, :summary, String.slice(content, 0, 200))

          _ ->
            part
        end

      "tool_result" ->
        tool_use_id = block["tool_use_id"] || block[:tool_use_id]
        content = block["content"] || block[:content] || ""
        is_error = block["is_error"] || block[:is_error] || false

        %{
          id: part_id,
          type: "tool_result",
          tool_use_id: tool_use_id,
          content: to_string(content),
          is_error: is_error
        }

      "image" ->
        source_map = block["source"] || block[:source] || %{}
        media_type = block["media_type"] || block[:media_type] ||
                     source_map["media_type"] || source_map[:media_type]
        data = source_map["data"] || source_map[:data]

        %{
          id: part_id,
          type: "image",
          media_type: media_type,
          source: if(data, do: "base64", else: "url")
        }

      nil ->
        nil

      other ->
        # Pass through unknown types as-is with the raw block data
        %{
          id: part_id,
          type: other,
          data: block
        }
    end
  end

  # --- Helpers ---

  defp extract_text(parts) do
    parts
    |> Enum.filter(&(&1[:type] == "text"))
    |> Enum.map_join("", &(&1[:text] || ""))
  end

  defp tool_call_status(nil), do: "complete"

  defp tool_call_status(result) do
    is_error = result["is_error"] || result[:is_error]
    if is_error, do: "error", else: "complete"
  end

  defp is_tool_result?(block) do
    (block["type"] || block[:type]) == "tool_result"
  end

  defp tool_result_only?(%Message{role: "user", content: content}) when is_list(content) do
    content != [] and Enum.all?(content, &is_tool_result?/1)
  end

  defp tool_result_only?(_), do: false

  defp orientation_origin?(%Message{origin: "orientation"}), do: true
  defp orientation_origin?(_), do: false
end
