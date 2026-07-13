defmodule Cranium.Inference.NativeHistory do
  @moduledoc """
  Native transcript history builder for Tiamat-style dispatch.

  This is intentionally separate from `Cranium.Inference.History`, which formats
  history for legacy provider chat APIs and appends an in-memory current user
  message. Native history preserves Cranium row identity and metadata so a turn
  request assembler can send durable transcript messages to Tiamat.
  """

  @doc """
  Return persisted messages shaped as native transcript rows.

  Options:
  - `:epoch_id` — scope history to an epoch.
  """
  @spec contribute(String.t(), keyword()) :: [map()]
  def contribute(conversation_id, opts \\ []) do
    epoch_id = Keyword.get(opts, :epoch_id)

    {:ok, messages} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

    Enum.map(messages, &format_message/1)
  end

  defp format_message(message) do
    %{
      id: message.id,
      parent_id: message.parent_id,
      created_at: format_timestamp(message.inserted_at),
      role: normalize_role(message),
      content: normalize_content_blocks(message.content),
      provenance: build_provenance(message)
    }
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(nil), do: nil

  defp normalize_role(%{role: role, content: content}) do
    if to_string(role) == "user" and tool_result_content?(content),
      do: "tool",
      else: to_string(role)
  end

  defp tool_result_content?(content) when is_list(content) do
    Enum.any?(content, fn block -> block_value(block, "type") == "tool_result" end)
  end

  defp tool_result_content?(_), do: false

  defp normalize_content_blocks(content) when is_list(content) do
    Enum.map(content, &normalize_content_block/1)
  end

  defp normalize_content_blocks(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp normalize_content_blocks(nil), do: []
  defp normalize_content_blocks(other), do: [%{"type" => "text", "text" => to_string(other)}]

  defp normalize_content_block(block) when is_map(block) do
    case block_value(block, "type") do
      "text" ->
        %{"type" => "text", "text" => block_value(block, "text") || ""}

      "tool_use" ->
        %{
          "type" => "tool_use",
          "tool_use_id" => block_value(block, "tool_use_id") || block_value(block, "id"),
          "tool_name" => block_value(block, "tool_name") || block_value(block, "name"),
          "tool_input" => block_value(block, "tool_input") || block_value(block, "input") || %{}
        }

      "tool_result" ->
        tool_output =
          if Map.has_key?(block, "tool_output") or Map.has_key?(block, :tool_output),
            do: block_value(block, "tool_output"),
            else: block_value(block, "content") || ""

        result = %{
          "type" => "tool_result",
          "tool_result_for" =>
            block_value(block, "tool_result_for") || block_value(block, "tool_use_id"),
          "tool_output" => tool_output
        }

        case block_value(block, "is_error") do
          nil -> result
          is_error -> Map.put(result, "is_error", is_error)
        end

      type when is_binary(type) ->
        block
        |> stringify_keys()
        |> Map.put("type", type)

      _ ->
        stringify_keys(block)
    end
  end

  defp normalize_content_block(other), do: %{"type" => "text", "text" => to_string(other)}

  defp build_provenance(message) do
    base =
      message.provenance
      |> normalize_map()
      |> Map.put_new("origin", message.origin || "cranium")

    case usage_value(message.usage, "model") do
      nil -> base
      model -> Map.put_new(base, "model", model)
    end
  end

  defp usage_value(nil, _key), do: nil
  defp usage_value(usage, key) when is_map(usage), do: block_value(usage, key)
  defp usage_value(_, _key), do: nil

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: stringify_keys(map)
  defp normalize_map(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp block_value(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end
end
