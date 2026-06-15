defmodule Cranium.Backend.LLM.OpenAIResponses.Messages do
  @moduledoc """
  Translates between cranium's internal (Anthropic-shaped) message format
  and the OpenAI Responses API input format.

  Internal format uses `role` + `content` blocks with types like `text`,
  `tool_use`, and `tool_result`. The Responses API uses a flat `input`
  array with typed items: bare messages, `function_call` items, and
  `function_call_output` items.
  """

  @doc """
  Translate internal messages into Responses API format.

  Returns `{instructions, input}` where `instructions` is the system
  prompt (or nil) and `input` is the list of Responses API input items.
  """
  @spec translate(list(), String.t() | nil) :: {String.t() | nil, list()}
  def translate(messages, system) do
    input = Enum.flat_map(messages, &translate_message/1)
    {system, input}
  end

  @doc """
  Translate cranium tool definitions to Responses API function format.
  """
  @spec translate_tools(list()) :: list()
  def translate_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      name = tool[:name] || tool["name"]
      desc = tool[:description] || tool["description"]
      schema = tool[:input_schema] || tool["input_schema"]

      %{type: "function", name: name, description: desc, parameters: schema, strict: false}
    end)
  end

  def translate_tools(_), do: []

  # --- Message Translation ---

  defp translate_message(msg) do
    role = to_string(msg[:role] || msg["role"])
    content = msg[:content] || msg["content"]

    case {role, content} do
      {"user", text} when is_binary(text) ->
        [%{role: "user", content: text}]

      {"assistant", text} when is_binary(text) ->
        [%{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}]

      {"user", blocks} when is_list(blocks) ->
        translate_user_blocks(blocks)

      {"assistant", blocks} when is_list(blocks) ->
        translate_assistant_blocks(blocks)

      _ ->
        []
    end
  end

  # User messages may contain text and/or tool_result blocks.
  # Tool results become function_call_output items; text becomes a user message.
  defp translate_user_blocks(blocks) do
    {tool_results, other} = split_tool_results(blocks)

    outputs =
      Enum.map(tool_results, fn block ->
        call_id = block[:tool_use_id] || block["tool_use_id"]
        content = block[:content] || block["content"]
        %{type: "function_call_output", call_id: call_id, output: stringify(content)}
      end)

    content_parts = input_content_parts(other)

    cond do
      content_parts == [] ->
        outputs

      Enum.any?(other, &Cranium.ImageInput.image_block?/1) ->
        outputs ++ [%{role: "user", content: content_parts}]

      true ->
        outputs ++ [%{role: "user", content: flatten_text(other)}]
    end
  end

  # Assistant messages may contain text and tool_use blocks.
  # Text becomes an output_text content part in a message item.
  # Tool uses become separate function_call items in the input array.
  defp translate_assistant_blocks(blocks) do
    text_parts =
      blocks
      |> Enum.flat_map(fn
        %{type: "text", text: t} -> [%{type: "output_text", text: t}]
        %{"type" => "text", "text" => t} -> [%{type: "output_text", text: t}]
        _ -> []
      end)

    tool_calls =
      blocks
      |> Enum.flat_map(fn
        %{type: "tool_use", id: id, name: name, input: input} ->
          [%{type: "function_call", call_id: id, name: name, arguments: Jason.encode!(input)}]

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [%{type: "function_call", call_id: id, name: name, arguments: Jason.encode!(input)}]

        _ ->
          []
      end)

    message =
      if text_parts != [] do
        [%{type: "message", role: "assistant", content: text_parts}]
      else
        []
      end

    message ++ tool_calls
  end

  # --- Helpers ---

  defp split_tool_results(blocks) do
    Enum.split_with(blocks, fn
      %{type: "tool_result"} -> true
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
  end

  defp flatten_text(blocks) do
    blocks
    |> Enum.map(fn
      %{text: t} -> t
      %{"text" => t} -> t
      %{type: "text", text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp input_content_parts(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{text: t} when is_binary(t) ->
        [%{type: "input_text", text: t}]

      %{"text" => t} when is_binary(t) ->
        [%{type: "input_text", text: t}]

      %{type: "text", text: t} when is_binary(t) ->
        [%{type: "input_text", text: t}]

      %{"type" => "text", "text" => t} when is_binary(t) ->
        [%{type: "input_text", text: t}]

      %{"type" => "image"} = block ->
        case Cranium.ImageInput.internal_image_to_responses_part(block) do
          nil -> []
          part -> [part]
        end

      %{type: "image"} = block ->
        case Cranium.ImageInput.internal_image_to_responses_part(block) do
          nil -> []
          part -> [part]
        end

      _ ->
        []
    end)
  end

  defp stringify(content) when is_binary(content), do: content
  defp stringify(content) when is_list(content), do: flatten_text(content)
  defp stringify(other), do: inspect(other)
end
