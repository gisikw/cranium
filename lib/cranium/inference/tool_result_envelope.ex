defmodule Cranium.Inference.ToolResultEnvelope do
  @moduledoc """
  Multimodal tool-result envelope detection and text rendering.

  Tools may return a structured content envelope instead of plain text
  (spec: hoard primers/multimodal-tool-results). A result is an envelope
  iff it is a JSON object whose top-level `"type"` is `"content"` and
  whose `"content"` is an array — anything else, including objects with
  a string `"content"` field, is legacy output. Every layer must use
  this exact discriminant.

  Cranium never interprets envelope contents for inference: the envelope
  travels as an opaque string inside `tool_result` content and Tiamat
  projects it per provider. This module exists for the places Cranium
  must *not* treat the string as plain text — byte-wise truncation
  (which would corrupt base64) and text-only consumers like summarizer
  and handoff transcripts (which must not receive base64 walls).
  """

  @doc """
  Parse a tool-result string as a content envelope.

  Returns `{:ok, blocks}` with the envelope's content blocks, or `:error`
  for anything that is not an envelope (legacy output, malformed JSON,
  non-binary values).
  """
  @spec parse(term()) :: {:ok, [map()]} | :error
  def parse(result) when is_binary(result) do
    with true <- String.starts_with?(String.trim_leading(result), "{"),
         {:ok, %{"type" => "content", "content" => blocks}} when is_list(blocks) <-
           Jason.decode(result) do
      {:ok, blocks}
    else
      _ -> :error
    end
  end

  def parse(_result), do: :error

  @doc "Whether a tool-result string is a content envelope."
  @spec envelope?(term()) :: boolean()
  def envelope?(result), do: match?({:ok, _}, parse(result))

  @doc """
  Render envelope blocks as plain text.

  Text blocks are joined with newlines; image blocks become
  `[image omitted]`; unknown block types become
  `[unsupported content block: <type>]` rather than being dropped.
  """
  @spec display_text([map()]) :: String.t()
  def display_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp block_text(%{"type" => "text"} = block) do
    case block["text"] do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp block_text(%{"type" => "image"}), do: "[image omitted]"

  defp block_text(%{"type" => type}) when is_binary(type),
    do: "[unsupported content block: #{type}]"

  defp block_text(_block), do: nil

  @doc """
  Replace envelope strings inside `tool_result` content blocks with their
  `display_text/1` rendering.

  Use this when message content feeds a text-only consumer (summary or
  handoff generation). Non-list content and non-envelope tool results
  pass through unchanged.
  """
  @spec redact_blocks(term()) :: term()
  def redact_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &redact_block/1)
  end

  def redact_blocks(content), do: content

  defp redact_block(%{} = block) do
    with "tool_result" <- block["type"] || block[:type],
         {:ok, envelope_blocks} <- parse(block["content"] || block[:content]) do
      put_content(block, display_text(envelope_blocks))
    else
      _ -> block
    end
  end

  defp redact_block(block), do: block

  defp put_content(block, text) do
    cond do
      Map.has_key?(block, "content") -> Map.put(block, "content", text)
      Map.has_key?(block, :content) -> Map.put(block, :content, text)
      true -> block
    end
  end
end
