defmodule Cranium.Egress.Chunker do
  @moduledoc """
  Segments streaming output into deliverable units.

  In voice mode, chunks at paragraph boundaries (`\\n\\n`) with a 30-word
  minimum for the first chunk and 100-word minimum for subsequent chunks,
  giving Kokoro TTS enough context for good prosody. In text mode, chunks
  at paragraph breaks for readable streaming updates.

  Also handles markers — these pass through without modification as
  positional cues for the transport.
  """

  @voice_first_words 30
  @voice_rest_words 100

  @spec process(term(), map()) :: {:ok, [term()]}
  def process(output, context) when is_binary(output) do
    mode = Map.get(context, :mode, :text)
    {:ok, chunk_text(output, mode)}
  end

  def process(%{type: :marker} = marker, _context) do
    {:ok, [marker]}
  end

  @doc """
  Process a single streaming chunk. Returns `:accumulate` if more data
  is needed, or `{:emit, data}` if a chunk boundary was reached.
  """
  @spec process_chunk(term()) :: :accumulate | {:emit, binary()}
  def process_chunk(%{type: :marker} = marker) do
    {:emit, marker}
  end

  def process_chunk(text) when is_binary(text) do
    # Simple heuristic: emit on sentence-ending punctuation
    if String.match?(text, ~r/[.!?]\s*$/) do
      {:emit, text}
    else
      :accumulate
    end
  end

  # --- Private ---

  defp chunk_text(text, :voice) do
    paragraphs =
      text
      |> String.split(~r/\n\n+/)
      |> Enum.reject(&(String.trim(&1) == ""))

    chunk_by_paragraph(paragraphs, @voice_first_words, @voice_rest_words)
  end

  defp chunk_text(text, :text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  # Accumulate paragraphs until word count >= threshold, then emit.
  # First chunk uses first_threshold; subsequent chunks use rest_threshold.
  # Always flush remaining paragraphs as a final chunk.
  defp chunk_by_paragraph(paragraphs, first_threshold, rest_threshold) do
    {chunks, current_paras, _threshold} =
      Enum.reduce(paragraphs, {[], [], first_threshold}, fn para, {chunks, acc, threshold} ->
        acc = acc ++ [para]
        word_count = acc |> Enum.join("\n\n") |> String.split() |> length()

        if word_count >= threshold do
          {[Enum.join(acc, "\n\n") | chunks], [], rest_threshold}
        else
          {chunks, acc, threshold}
        end
      end)

    # Flush any remaining paragraphs
    case {current_paras, chunks} do
      {[], _} ->
        Enum.reverse(chunks)

      {remainder, _} ->
        Enum.reverse([Enum.join(remainder, "\n\n") | chunks])
    end
  end
end
