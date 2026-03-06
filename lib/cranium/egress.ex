defmodule Cranium.Egress do
  @moduledoc """
  Output processing stage.

  Transforms streaming agent output into deliverable formats. This stage
  is streaming-native — it receives chunks from the Agent and forwards
  processed output to transports.

  Decomposes into two steps:

  - `Chunker` — segments streaming text into deliverable units. In voice
    mode, chunks at sentence boundaries for natural TTS pacing. In text
    mode, chunks at paragraph breaks for readable streaming.
  - `Synthesizer` — routes text chunks through TTS backend when in voice
    mode. Pass-through in text mode.

  ## Incremental Manifest Population

  Egress pushes segments to the Manifest as they arrive. Text accumulates
  in a per-stream buffer. When a paragraph boundary (`\\n\\n`) is detected,
  everything before it is emitted as one or more segments. On stream end,
  remaining text becomes the final segment.

  When the client's disposition includes "audio", Egress eagerly warms
  the TTS cache for each emitted segment.

  ## Mode

  Egress operates in one of two modes, set per-session:

  - `:text` — chunks are delivered as text to the transport
  - `:voice` — chunks are synthesized to audio, then delivered

  The model doesn't know which mode it's in. Mode is a session-level flag
  that the transport can toggle.

  ## Markers

  SCTE markers from the Agent pass through Egress without modification.
  They're positional cues for the transport — "show this image here,"
  "display this code block here." The transport decides how to render them.
  """

  use GenServer

  require Logger

  defstruct mode: :text, streams: %{}

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Process a complete output through chunking and optional synthesis.
  """
  @spec process(term(), map()) :: {:ok, [term()]}
  def process(output, context) do
    mode = Map.get(context, :mode, :text)

    with {:ok, chunks} <- Cranium.Egress.Chunker.process(output, context) do
      if mode == :voice do
        Cranium.Egress.Synthesizer.process(chunks, context)
      else
        {:ok, chunks}
      end
    end
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(_opts) do
    Logger.info("Egress stage started", stage: :egress)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:process, output, context}, _from, state) do
    result = process(output, context)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:stream_start, stream_id, metadata}, state) do
    Logger.debug("Stream started",
      stage: :egress,
      stream_id: stream_id,
      mode: Map.get(metadata, :mode, :text)
    )

    disposition = Map.get(metadata, :disposition, ["text"])

    streams =
      Map.put(state.streams, stream_id, %{
        text: "",
        segment_index: 0,
        disposition: disposition
      })

    mode = Map.get(metadata, :mode, state.mode)
    {:noreply, %{state | streams: streams, mode: mode}}
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, chunk}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        text = stream.text <> chunk

        {emittable, remainder} = split_paragraphs(text)
        {new_index, leftover} = batch_and_emit(emittable, remainder, stream, stream_id)

        stream = %{stream | text: leftover, segment_index: new_index}
        {:noreply, %{state | streams: Map.put(state.streams, stream_id, stream)}}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:stream_end, stream_id}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        remaining = String.trim(stream.text)

        if remaining != "" do
          emit_segment(stream_id, stream.segment_index, remaining, stream.disposition)
        end

        Cranium.Manifest.complete(stream_id)

        {:noreply, %{state | streams: Map.delete(state.streams, stream_id)}}

      :error ->
        {:noreply, state}
    end
  end

  # --- Private ---

  @first_batch_words 30
  @subsequent_batch_words 100

  defp split_paragraphs(text) do
    case String.split(text, ~r/\n\n+/, parts: :infinity) do
      [single] ->
        {[], single}

      parts ->
        {segments, [remainder]} = Enum.split(parts, -1)
        segments = segments |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        {segments, remainder}
    end
  end

  # Merge paragraphs until word threshold is met, then emit.
  # First segment: emit on first paragraph break on or after 30 words.
  # Subsequent: on or after 100 words.
  defp batch_and_emit([], remainder, stream, _stream_id) do
    {stream.segment_index, remainder}
  end

  defp batch_and_emit(paragraphs, remainder, stream, stream_id) do
    threshold = if stream.segment_index == 0, do: @first_batch_words, else: @subsequent_batch_words

    {index, acc} =
      Enum.reduce(paragraphs, {stream.segment_index, ""}, fn para, {idx, acc} ->
        merged = if acc == "", do: para, else: acc <> "\n\n" <> para

        if word_count(merged) >= threshold do
          emit_segment(stream_id, idx, merged, stream.disposition)
          {idx + 1, ""}
        else
          {idx, merged}
        end
      end)

    # Any accumulated text that didn't meet threshold goes back into the buffer
    # along with the remainder (incomplete paragraph still streaming in)
    leftover =
      case {acc, remainder} do
        {"", r} -> r
        {a, ""} -> a
        {a, r} -> a <> "\n\n" <> r
      end

    {index, leftover}
  end

  defp word_count(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp emit_segment(stream_id, index, text, disposition) do
    Cranium.Manifest.add_utterance(stream_id, index, text)

    if "audio" in disposition do
      warm_tts(stream_id, index, text)
    end

    Logger.debug("Segment emitted",
      stage: :egress,
      stream_id: stream_id,
      segment: index,
      length: String.length(text)
    )
  end

  defp warm_tts(stream_id, index, text) do
    backend = Application.get_env(:cranium, :backends)[:tts] || Cranium.Backend.TTS.Kokoro

    case backend.synthesize(text, []) do
      {:ok, audio} ->
        Cranium.TTS.Cache.put(stream_id, index, audio)

      {:error, reason} ->
        Logger.error("TTS warm failed: stream=#{stream_id} segment=#{index} reason=#{inspect(reason)}",
          stage: :egress
        )
    end
  end
end
