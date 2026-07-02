defmodule Cranium.Media.OutputSegmenter do
  @moduledoc """
  Segments streaming agent output into deliverable units.

  Receives raw stream events (stream_start, chunk, stream_end) from the Agent
  via Cranium.Events and produces segments for downstream consumers. Each
  segment is pushed to the Manifest (for pull-based clients) and broadcast as
  a `{:segment_ready, ...}` event (for future Transport actors).

  ## Segmentation Strategy

  Text accumulates in a per-stream buffer. When a paragraph boundary (`\\n\\n`)
  is detected, everything before it is emitted as one or more segments. On
  stream end, remaining text becomes the final segment.

  When the client's disposition includes "audio", the segmenter uses adaptive
  lead-time chunking to keep TTS synthesis ahead of playback. Batch sizes are
  derived from estimated lead time — how far ahead synthesized audio is relative
  to wall clock. When lead time is low (aggressive mode), segments are emitted
  at sentence boundaries for faster synthesis turnaround. When lead time is
  comfortable (relaxed mode), segments are emitted at paragraph boundaries for
  better prosody.

  ## Markers

  SCTE markers from the Agent pass through without modification. They're
  positional cues for the transport — "show this image here," "display this
  code block here." The transport decides how to render them.

  ## Idle Flush

  For audio streams, a 1-second idle timer flushes any buffered text that
  hasn't met the word threshold. This prevents dead air during tool execution
  gaps — e.g. "Give me a minute." sitting unsynthesized while a Read tool
  runs for 10 seconds. The timer resets on every text chunk and is cancelled
  on stream_end or cue chunks (which flush explicitly).
  """

  use GenServer

  require Logger

  use TypedStruct

  typedstruct do
    field :mode, :text | :voice, default: :text
    field :streams, map(), default: %{}
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # --- GenServer Implementation ---

  @impl GenServer
  def init(_opts) do
    Logger.info("OutputSegmenter started", stage: :output_segmenter)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:subscribe_stream, stream_id}, _from, state) do
    {:ok, _} = Cranium.Events.subscribe({:stream_raw, stream_id})
    {:reply, :ok, state}
  end

  # Synchronization barrier: guarantees that stream_end (and its segment_ready
  # emissions) have been processed before the caller continues. Called by
  # Harness before emitting pass_complete so the Manifest has all segments
  # before transitioning to "complete".
  def handle_call({:drain_stream, _stream_id}, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:stream_start, stream_id, metadata}, state) do
    Logger.debug("Stream started",
      stage: :output_segmenter,
      stream_id: stream_id,
      mode: Map.get(metadata, :mode, :text)
    )

    disposition = Map.get(metadata, :disposition, ["text"])

    streams =
      Map.put(state.streams, stream_id, %{
        text: "",
        segment_index: 0,
        disposition: disposition,
        conversation_id: Map.get(metadata, :conversation_id),
        first_emit_at: nil,
        words_emitted: 0,
        flush_ref: nil
      })

    mode = Map.get(metadata, :mode, state.mode)
    {:noreply, %{state | streams: streams, mode: mode}}
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, chunk}, state) when is_binary(chunk) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        stream = %{stream | text: stream.text <> chunk}

        stream =
          if needs_aggressive_chunking?(stream) do
            aggressive_chunk(stream, stream_id)
          else
            relaxed_chunk(stream, stream_id)
          end

        # Schedule idle flush for audio streams with buffered text.
        # Catches tool execution gaps where no more chunks arrive for seconds.
        stream = schedule_idle_flush(stream, stream_id)

        {:noreply, %{state | streams: Map.put(state.streams, stream_id, stream)}}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:chunk, stream_id, {cue_type, data}}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        # Cancel idle timer — explicit flush supersedes it
        stream = cancel_idle_flush(stream)

        # Flush any buffered text before the cue so segment ordering matches stream order
        stream = flush_text_buffer(stream, stream_id)

        Cranium.Events.broadcast(stream.conversation_id,
          {:segment_ready, stream_id, stream.segment_index,
           %{type: :cue, cue_type: cue_type, data: data}}
        )

        stream = %{stream | segment_index: stream.segment_index + 1}
        {:noreply, %{state | streams: Map.put(state.streams, stream_id, stream)}}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:stream_end, stream_id}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        stream = cancel_idle_flush(stream)
        remaining = String.trim(stream.text)

        if remaining != "" do
          emit_segment(stream.conversation_id, stream_id, stream.segment_index, remaining, stream.disposition)
        end

        {:noreply, %{state | streams: Map.delete(state.streams, stream_id)}}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:idle_flush, stream_id}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, stream} ->
        stream = %{stream | flush_ref: nil}

        remaining = String.trim(stream.text)

        if remaining != "" do
          Logger.debug(
            "Idle flush: stream=#{stream_id} words=#{word_count(remaining)}",
            stage: :output_segmenter
          )

          stream = flush_text_buffer(stream, stream_id)
          {:noreply, %{state | streams: Map.put(state.streams, stream_id, stream)}}
        else
          {:noreply, %{state | streams: Map.put(state.streams, stream_id, stream)}}
        end

      :error ->
        {:noreply, state}
    end
  end

  # Catch-all for lifecycle events (e.g. :pass_complete) dispatched on the
  # stream topic via Event.broadcast/3. OutputSegmenter only cares about
  # stream_start, chunk, and stream_end — everything else is safely ignored.
  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  # Flush any accumulated text as an utterance segment, ignoring word thresholds.
  # Used before emitting cues to preserve stream ordering.
  defp flush_text_buffer(stream, stream_id) do
    remaining = String.trim(stream.text)

    if remaining != "" do
      emit_segment(stream.conversation_id, stream_id, stream.segment_index, remaining, stream.disposition)

      %{stream | text: "", segment_index: stream.segment_index + 1}
      |> track_emission(word_count(remaining))
    else
      stream
    end
  end

  # Idle flush: dispatch buffered text after 1s of no new chunks.
  # Prevents dead air during tool execution or model thinking pauses.
  @idle_flush_ms 1_000

  # Schedule an idle flush timer for audio streams with buffered text.
  # Resets any existing timer. No-ops for text-only streams or empty buffers.
  defp schedule_idle_flush(stream, stream_id) do
    if "audio" in stream.disposition and String.trim(stream.text) != "" do
      stream = cancel_idle_flush(stream)
      ref = Process.send_after(self(), {:idle_flush, stream_id}, @idle_flush_ms)
      %{stream | flush_ref: ref}
    else
      stream
    end
  end

  defp cancel_idle_flush(%{flush_ref: nil} = stream), do: stream

  defp cancel_idle_flush(%{flush_ref: ref} = stream) do
    Process.cancel_timer(ref)
    # Drain any already-delivered timer message
    receive do
      {:idle_flush, _} -> :ok
    after
      0 -> :ok
    end

    %{stream | flush_ref: nil}
  end

  @first_batch_words 30
  @subsequent_batch_words 100

  # Adaptive lead-time chunking constants.
  # When audio disposition is active, OutputSegmenter estimates how far ahead
  # the TTS pipeline is relative to playback. The batch size is derived from
  # lead time: lead must cover the chunk's synthesis time, or the client
  # stalls waiting for audio. The warmer is sequential — the entire chunk
  # must finish synthesizing before any of its audio is available.
  #
  # Measured empirically: 2.2-2.8 WPS across clip lengths.
  # Using 2.3 (short-clip average) — underestimates lead time slightly,
  # which errs toward staying aggressive longer. Safe direction.
  @speech_rate_wps 2.3
  @sentence_min_words 8
  # Measured empirically on Qwen3-TTS 0.6B / RTX 3090: 0.67-0.71 RTF
  # across clip lengths (non-linear, short clips have worse RTF). Used to
  # cap lead time at what synthesis could have actually produced — prevents
  # burst scenarios from inflating lead time when no audio has been
  # synthesized yet.
  @synth_rtf 0.70
  # Minimum batch size worth switching to relaxed mode for — prosody
  # benefit below this threshold is negligible vs sentence-level chunking.
  @min_relaxed_words 20
  # Hard cap on audio batch size. Limits worst-case synthesis time to
  # ~20s at RTF 0.91. Larger chunks don't improve prosody enough to
  # justify the stall risk.
  @max_batch_words 50

  # --- Adaptive lead-time chunking ---

  defp lead_time_ms(%{first_emit_at: nil}), do: 0

  defp lead_time_ms(%{first_emit_at: t, words_emitted: w}) do
    audio_ms = w / @speech_rate_wps * 1000
    elapsed = System.monotonic_time(:millisecond) - t

    # Raw lead time: how far ahead audio content is vs wall clock
    raw_lead = trunc(audio_ms - elapsed)

    # Cap at what synthesis could have actually produced. The warmer runs
    # at RTF, so net lead accrues at (1/RTF - 1) per second of wall time.
    # In burst scenarios (elapsed ≈ 0), this correctly yields ~0 even with
    # lots of queued words — because no synthesis has happened yet.
    max_lead = trunc(elapsed * (1.0 / @synth_rtf - 1.0))

    min(raw_lead, max_lead)
  end

  # Maximum words we can safely queue for synthesis given current lead time.
  # The warmer is sequential — the entire chunk must complete before the
  # client can play it. Lead must cover the chunk's synthesis time:
  #   lead >= words / wps * 1000 * rtf
  #   → words <= lead * wps / (1000 * rtf)
  defp safe_batch_words(stream) do
    lead = lead_time_ms(stream)
    safe = trunc(lead * @speech_rate_wps / (1000.0 * @synth_rtf))
    safe |> max(@sentence_min_words) |> min(@max_batch_words)
  end

  defp needs_aggressive_chunking?(stream) do
    "audio" in stream.disposition and safe_batch_words(stream) < @min_relaxed_words
  end

  # Aggressive mode: emit paragraphs immediately when they fit within the
  # available runway (better prosody). When a paragraph exceeds the safe
  # batch size, sentence-split it to avoid dead air — a 50-word paragraph
  # that takes 15s to synthesize will stall the client if only 8s of audio
  # is buffered. Falls back to sentence-level splitting when no paragraph
  # break exists yet.
  defp aggressive_chunk(stream, stream_id) do
    case split_paragraphs(stream.text) do
      {[_ | _] = paragraphs, remainder} ->
        max_words = safe_batch_words(stream)

        {index, stream} =
          Enum.reduce(paragraphs, {stream.segment_index, stream}, fn para, {idx, s} ->
            if word_count(para) <= max_words do
              # Paragraph fits within runway — emit whole for better prosody
              emit_segment(s.conversation_id, stream_id, idx, para, s.disposition)

              Logger.debug(
                "Aggressive emit (para): segment=#{idx} words=#{word_count(para)} safe=#{max_words} lead_time=#{lead_time_ms(s)}ms",
                stage: :output_segmenter,
                stream_id: stream_id
              )

              {idx + 1, track_emission(s, word_count(para))}
            else
              # Paragraph too large for runway — sentence-split it
              Logger.debug(
                "Aggressive split (para too large): words=#{word_count(para)} safe=#{max_words} lead_time=#{lead_time_ms(s)}ms",
                stage: :output_segmenter,
                stream_id: stream_id
              )

              sentence_split_and_emit(para, idx, s, stream_id)
            end
          end)

        stream = %{stream | text: remainder, segment_index: index}

        if needs_aggressive_chunking?(stream) do
          aggressive_chunk(stream, stream_id)
        else
          stream
        end

      {[], _} ->
        # No paragraph break yet — try sentence boundary
        case split_at_sentence(stream.text, @sentence_min_words) do
          {emittable, remainder} ->
            emit_segment(stream.conversation_id, stream_id, stream.segment_index, emittable, stream.disposition)

            Logger.debug(
              "Aggressive emit (sentence): segment=#{stream.segment_index} words=#{word_count(emittable)} lead_time=#{lead_time_ms(stream)}ms",
              stage: :output_segmenter,
              stream_id: stream_id
            )

            stream =
              %{stream | text: remainder, segment_index: stream.segment_index + 1}
              |> track_emission(word_count(emittable))

            if needs_aggressive_chunking?(stream) do
              aggressive_chunk(stream, stream_id)
            else
              stream
            end

          nil ->
            stream
        end
    end
  end

  # Recursively sentence-split a paragraph that's too large for the current
  # runway. Emits each sentence as its own segment. Any trailing text without
  # a sentence boundary is emitted as a final segment (it's from a complete
  # paragraph, so we know no more words will be appended).
  defp sentence_split_and_emit(text, index, stream, stream_id) do
    case split_at_sentence(text, @sentence_min_words) do
      {emittable, remainder} ->
        emit_segment(stream.conversation_id, stream_id, index, emittable, stream.disposition)

        Logger.debug(
          "Aggressive emit (sentence from para): segment=#{index} words=#{word_count(emittable)}",
          stage: :output_segmenter,
          stream_id: stream_id
        )

        stream = track_emission(stream, word_count(emittable))
        sentence_split_and_emit(String.trim_leading(remainder), index + 1, stream, stream_id)

      nil ->
        # No more sentence boundaries — emit remaining text
        trimmed = String.trim(text)

        if trimmed != "" do
          emit_segment(stream.conversation_id, stream_id, index, trimmed, stream.disposition)
          {index + 1, track_emission(stream, word_count(trimmed))}
        else
          {index, stream}
        end
    end
  end

  # Relaxed mode: paragraph-based batching with word thresholds.
  # For audio disposition, the batch size is derived from current lead time
  # to ensure the warmer can synthesize the chunk before playback catches up.
  # For text-only, uses fixed thresholds (30 first / 100 subsequent).
  defp relaxed_chunk(stream, stream_id) do
    original_text = stream.text
    original_index = stream.segment_index
    {emittable, remainder} = split_paragraphs(original_text)

    threshold =
      cond do
        stream.segment_index == 0 -> @first_batch_words
        "audio" in stream.disposition -> safe_batch_words(stream)
        true -> @subsequent_batch_words
      end

    {new_index, leftover} = batch_and_emit(emittable, remainder, stream, stream_id, threshold)

    stream = %{stream | text: leftover, segment_index: new_index}

    if new_index > original_index do
      Logger.debug(
        "Relaxed emit: threshold=#{threshold} lead_time=#{lead_time_ms(stream)}ms",
        stage: :output_segmenter,
        stream_id: stream_id
      )

      emitted_words = word_count(original_text) - word_count(leftover)
      track_emission(stream, emitted_words)
    else
      stream
    end
  end

  defp track_emission(stream, 0), do: stream

  defp track_emission(stream, words) do
    now = System.monotonic_time(:millisecond)

    %{
      stream
      | first_emit_at: stream.first_emit_at || now,
        words_emitted: stream.words_emitted + words
    }
  end

  # Find the earliest sentence boundary ([.!?] followed by whitespace) where
  # the text up to that point has at least min_words words.
  defp split_at_sentence(text, min_words) do
    case Regex.scan(~r/[.!?](?=\s)/, text, return: :index) do
      [] ->
        nil

      matches ->
        Enum.find_value(matches, fn [{start, len}] ->
          split_pos = start + len
          before = :binary.part(text, 0, split_pos)
          after_text = :binary.part(text, split_pos, byte_size(text) - split_pos)

          if word_count(before) >= min_words and String.trim(after_text) != "" do
            {String.trim(before), String.trim_leading(after_text)}
          end
        end)
    end
  end

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
  defp batch_and_emit([], remainder, stream, _stream_id, _threshold) do
    {stream.segment_index, remainder}
  end

  defp batch_and_emit(paragraphs, remainder, stream, stream_id, threshold) do
    {index, acc} =
      Enum.reduce(paragraphs, {stream.segment_index, ""}, fn para, {idx, acc} ->
        merged = if acc == "", do: para, else: acc <> "\n\n" <> para

        if word_count(merged) >= threshold do
          emit_segment(stream.conversation_id, stream_id, idx, merged, stream.disposition)
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

  defp emit_segment(conversation_id, stream_id, index, text, disposition) do
    if "audio" in disposition do
      warm_tts(stream_id, index, text)
    end

    renditions = if "audio" in disposition, do: [:text, :audio], else: [:text]

    Cranium.Events.broadcast(
      conversation_id,
      {:segment_ready, stream_id, index, %{type: :utterance, text: text, renditions: renditions}}
    )

    Logger.debug("Segment emitted",
      stage: :output_segmenter,
      stream_id: stream_id,
      segment: index,
      length: String.length(text)
    )
  end

  defp warm_tts(stream_id, index, text) do
    Cranium.Media.TTS.Cache.mark_warming(stream_id, index)
    Cranium.Media.TTS.Warmer.enqueue(stream_id, index, text)
  end
end
