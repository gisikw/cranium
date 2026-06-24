defmodule Cranium.Backend.LLM.Tiamat.Events do
  @moduledoc false

  @schema "tiamat.turn.event.v1"

  @doc """
  Decode an SSE event from Tiamat.

  The native stream carries provider-neutral event envelopes in `data`. While the
  adapter is rolling forward, this also accepts the legacy `event: turn_response`
  shape where the SSE data is the response object directly.
  """
  def decode_sse(%{event: "turn_response", data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"schema" => @schema} = envelope} -> {:ok, envelope}
      {:ok, response} -> {:ok, legacy_turn_response(response)}
      {:error, error} -> {:error, error}
    end
  end

  def decode_sse(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"schema" => @schema} = envelope} -> {:ok, envelope}
      {:ok, %{"type" => _type, "payload" => _payload} = envelope} -> {:ok, envelope}
      {:ok, _other} -> :ignore
      {:error, error} -> {:error, error}
    end
  end

  def decode_sse(_), do: :ignore

  def type(%{"type" => type}) when is_binary(type), do: type
  def type(_), do: nil

  def payload(%{"payload" => payload}) when is_map(payload), do: payload
  def payload(_), do: %{}

  def turn_response(%{"type" => "turn_response"} = envelope) do
    case payload(envelope) do
      %{"response" => %{} = response} -> {:ok, response}
      %{} = response when map_size(response) > 0 -> {:ok, response}
      _ -> :error
    end
  end

  def turn_response(_), do: :error

  def normalization_delta(%{"type" => "normalization_delta"} = envelope), do: payload(envelope)
  def normalization_delta(_), do: nil

  def text_delta(%{"type" => "content_part_delta"} = envelope) do
    payload = payload(envelope)

    if content_type(payload) == "text" do
      payload
      |> map_value("delta")
      |> text_from_delta()
    else
      nil
    end
  end

  def text_delta(_), do: nil

  def completed_content(%{"type" => "content_part_completed"} = envelope) do
    payload = payload(envelope)

    with "completed" <- map_value(payload, "completion_status") || "completed",
         %{} = content <- map_value(payload, "content") do
      [normalize_content_block(content, payload)]
    else
      _ -> []
    end
  end

  def completed_content(_), do: []

  def completed_text(%{"type" => "content_part_completed"} = envelope) do
    payload = payload(envelope)

    with "text" <- content_type(payload),
         "completed" <- map_value(payload, "completion_status") || "completed",
         %{} = content <- map_value(payload, "content"),
         text when is_binary(text) and text != "" <- map_value(content, "text") do
      text
    else
      _ -> nil
    end
  end

  def completed_text(_), do: nil

  def part_id(envelope), do: map_value(payload(envelope), "part_id")

  def message_content(%{"type" => "assistant_message_completed"} = envelope) do
    payload = payload(envelope)

    with "completed" <- map_value(payload, "completion_status") || "completed",
         %{} = message <- map_value(payload, "message"),
         content when is_list(content) <- map_value(message, "content") do
      Enum.map(content, &normalize_content_block(&1, %{}))
    else
      _ -> []
    end
  end

  def message_content(_), do: []

  def tool_calls(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(map_value(&1, "type") == "tool_use"))
    |> Enum.map(fn block ->
      %{
        id: map_value(block, "tool_use_id") || map_value(block, "id"),
        name: map_value(block, "tool_name") || map_value(block, "name"),
        input: map_value(block, "tool_input") || map_value(block, "input") || %{}
      }
    end)
    |> Enum.reject(fn %{id: id, name: name} -> not is_binary(id) or not is_binary(name) end)
  end

  def usage(%{"type" => "usage_update"} = envelope) do
    case map_value(payload(envelope), "usage") do
      %{} = usage -> usage
      _ -> nil
    end
  end

  def usage(_), do: nil

  def failure_reason(%{"type" => "turn_failed"} = envelope) do
    payload = payload(envelope)

    %{
      phase: map_value(payload, "phase"),
      error_code: map_value(payload, "error_code"),
      errors: map_value(payload, "errors") || []
    }
  end

  def failure_reason(_), do: nil

  defp legacy_turn_response(response) do
    %{
      "schema" => @schema,
      "type" => "turn_response",
      "payload" => %{"response" => response}
    }
  end

  defp content_type(payload), do: map_value(payload, "content_type") || map_value(payload, "type")

  defp text_from_delta(text) when is_binary(text), do: reject_empty(text)
  defp text_from_delta(%{"text" => text}) when is_binary(text), do: reject_empty(text)
  defp text_from_delta(%{text: text}) when is_binary(text), do: reject_empty(text)
  defp text_from_delta(%{"value" => text}) when is_binary(text), do: reject_empty(text)
  defp text_from_delta(%{value: text}) when is_binary(text), do: reject_empty(text)
  defp text_from_delta(_), do: nil

  defp reject_empty(""), do: nil
  defp reject_empty(text), do: text

  defp normalize_content_block(block, payload) when is_map(block) do
    block
    |> stringify_keys()
    |> maybe_put_type(payload)
  end

  defp normalize_content_block(other, payload) do
    %{"type" => content_type(payload) || "other", "opaque_payload" => other}
  end

  defp maybe_put_type(block, payload) do
    case map_value(block, "type") do
      type when is_binary(type) -> block
      _ -> Map.put(block, "type", content_type(payload) || "other")
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
