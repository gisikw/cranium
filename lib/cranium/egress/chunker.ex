defmodule Cranium.Egress.Chunker do
  @moduledoc """
  Segments streaming output into deliverable units.

  In voice mode, chunks at sentence boundaries for natural TTS pacing
  (50-100 word target per chunk). In text mode, chunks at paragraph
  breaks for readable streaming updates.

  Also handles markers — these pass through without modification as
  positional cues for the transport.
  """

  @voice_target_words 75
  @voice_min_words 20

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
    text
    |> String.split(~r/(?<=[.!?])\s+/)
    |> chunk_by_word_count(@voice_target_words, @voice_min_words)
  end

  defp chunk_text(text, :text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp chunk_by_word_count(sentences, target, min) do
    {chunks, current} =
      Enum.reduce(sentences, {[], ""}, fn sentence, {chunks, current} ->
        combined = if current == "", do: sentence, else: current <> " " <> sentence
        word_count = combined |> String.split() |> length()

        if word_count >= target do
          {[combined | chunks], ""}
        else
          {chunks, combined}
        end
      end)

    # Don't leave a tiny remainder — merge with last chunk
    case {current, chunks} do
      {"", chunks} ->
        Enum.reverse(chunks)

      {remainder, [last | rest]} ->
        word_count = remainder |> String.split() |> length()

        if word_count < min do
          Enum.reverse([last <> " " <> remainder | rest])
        else
          Enum.reverse([remainder, last | rest])
        end

      {remainder, chunks} ->
        Enum.reverse([remainder | chunks])
    end
  end
end
