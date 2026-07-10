defmodule Cranium.Inference.SuppressedThought do
  @moduledoc """
  Strips `<suppressed>...</suppressed>` spans from assistant output.

  The tag is a discretion channel: content inside a span never reaches any
  user-facing surface (stream chunks, persisted history, room events,
  turn-state snapshots, summaries, handoffs). The stripped spans are
  journaled by `Cranium.Store.SuppressionJournal` — the journal is the only
  place they live.

  This module is pure — it takes text, returns stripped text plus the spans
  it removed. Journaling (I/O) is the caller's job. The Agent runs the
  incremental filter (`push/2`/`finish/1`) at stream ingress so every
  fan-out point sees only stripped text; `Cranium.Effects.PassReactor` runs
  `strip/1`/`strip_content/1` as the guarantee at the Store boundary.

  ## Rules

  - Multiple spans per message, multiline content allowed.
  - An opening tag with no close strips from the tag to end of message and
    the buffered content is still reported as a span (fail closed).
  - Whitespace collapses cleanly: the whitespace on either side of a removed
    span merges to a blank line, a newline, or a single space — whichever the
    surroundings already used — so no dangling blank lines remain. Text with
    no spans passes through untouched.
  - Spans are deduplicated by exact content within one filter instance, so a
    span reported by both the text stream and native content blocks is
    counted once.
  """

  use TypedStruct

  @open "<suppressed>"
  @close "</suppressed>"
  @ws ~c" \t\n\r"

  typedstruct do
    field :mode, :pass | :suppress, default: :pass
    # :pass — tail held back because it may become a span boundary in a later
    # chunk (trailing whitespace and/or a partial open tag).
    # :suppress — span content accumulated since the open tag.
    field :buf, String.t(), default: ""
    # Collapsed whitespace owed at the seam of a removed span, pending until
    # the next visible text. nil means no removal is pending.
    field :joint, String.t() | nil, default: nil
    field :emitted?, boolean(), default: false
    # Every span seen so far, newest first. Doubles as the dedupe set.
    field :spans, [String.t()], default: []
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "All spans seen by this filter instance, in order of discovery."
  @spec spans(t()) :: [String.t()]
  def spans(%__MODULE__{spans: spans}), do: Enum.reverse(spans)

  @doc """
  Feed a chunk through the filter.

  Returns `{visible, new_spans, state}` — the text safe to emit now, any
  spans closed by this chunk (already deduplicated), and the updated state.
  """
  @spec push(t(), String.t()) :: {String.t(), [String.t()], t()}
  def push(%__MODULE__{} = t, text) when is_binary(text) do
    scan(%{t | buf: ""}, t.buf <> text, "", [])
  end

  @doc """
  End of message. Releases any held-back literal tail; an open span becomes
  a reported span (fail closed — its content is never emitted). Trailing
  whitespace owed at a span seam is dropped rather than dangled.
  """
  @spec finish(t()) :: {String.t(), [String.t()], t()}
  def finish(%__MODULE__{mode: :suppress} = t) do
    {t, new_spans} = record_span(t, t.buf)
    {"", new_spans, %{t | mode: :pass, buf: "", joint: nil}}
  end

  def finish(%__MODULE__{} = t) do
    visible =
      case t.buf do
        "" -> ""
        buf -> seam(t) <> buf
      end

    {visible, [], %{t | buf: "", joint: nil, emitted?: t.emitted? or visible != ""}}
  end

  @doc "Strip a complete message in one call."
  @spec strip(String.t()) :: {String.t(), [String.t()]}
  def strip(text) when is_binary(text) do
    {head, head_spans, t} = push(new(), text)
    {tail, tail_spans, _t} = finish(t)
    {head <> tail, head_spans ++ tail_spans}
  end

  @doc """
  Strip text-type content blocks, threading the filter state so spans the
  stream already reported are not double-counted. Text blocks emptied by
  stripping are dropped.
  """
  @spec strip_blocks([map()], t()) :: {[map()], [String.t()], t()}
  def strip_blocks(blocks, %__MODULE__{} = t) when is_list(blocks) do
    {kept, new_spans, t} =
      Enum.reduce(blocks, {[], [], t}, fn block, {kept, new_spans, t} ->
        case strip_block(block) do
          {block, []} ->
            {[block | kept], new_spans, t}

          {block, spans} ->
            {t, recorded} = record_spans(t, spans)
            kept = if empty_text_block?(block), do: kept, else: [block | kept]
            {kept, new_spans ++ recorded, t}
        end
      end)

    {Enum.reverse(kept), new_spans, t}
  end

  @doc "Strip message content — a string or a content-block list."
  @spec strip_content(term()) :: {term(), [String.t()]}
  def strip_content(content) when is_binary(content), do: strip(content)

  def strip_content(content) when is_list(content) do
    {blocks, spans, _t} = strip_blocks(content, new())
    {blocks, spans}
  end

  def strip_content(content), do: {content, []}

  # --- Scanner ---

  defp scan(%{mode: :pass} = t, work, out, new_spans) do
    {t, work} = absorb_joint_ws(t, work)

    case :binary.match(work, @open) do
      {i, tag_len} ->
        before = binary_part(work, 0, i)
        rest = binary_part(work, i + tag_len, byte_size(work) - i - tag_len)
        {visible, ws} = split_trailing_ws(before)
        {t, out} = emit(t, out, visible)
        scan(%{t | mode: :suppress, joint: merge_ws(t.joint, ws)}, rest, out, new_spans)

      :nomatch ->
        keep = holdback_index(work)
        visible = binary_part(work, 0, keep)
        tail = binary_part(work, keep, byte_size(work) - keep)
        {t, out} = emit(t, out, visible)
        {out, new_spans, %{t | buf: tail}}
    end
  end

  defp scan(%{mode: :suppress} = t, work, out, new_spans) do
    case :binary.match(work, @close) do
      {i, tag_len} ->
        span = binary_part(work, 0, i)
        rest = binary_part(work, i + tag_len, byte_size(work) - i - tag_len)
        {t, recorded} = record_span(t, span)
        scan(%{t | mode: :pass}, rest, out, new_spans ++ recorded)

      :nomatch ->
        {out, new_spans, %{t | buf: work}}
    end
  end

  defp absorb_joint_ws(%{joint: nil} = t, work), do: {t, work}

  defp absorb_joint_ws(%{joint: joint} = t, work) do
    {ws, rest} = split_leading_ws(work)
    {%{t | joint: merge_ws(joint, ws)}, rest}
  end

  defp emit(t, out, ""), do: {t, out}

  defp emit(t, out, visible) do
    {%{t | joint: nil, emitted?: true}, out <> seam(t) <> visible}
  end

  # Whitespace owed where a span was removed. Nothing is owed before the
  # first visible text — a message must not start with seam whitespace.
  defp seam(%{joint: joint, emitted?: true}) when is_binary(joint), do: joint
  defp seam(_t), do: ""

  # The removed span's neighbors keep whichever separation they already had:
  # a blank line stays a blank line, a newline stays a newline, anything
  # else collapses to one space.
  defp merge_ws(nil, ws), do: ws

  defp merge_ws(a, b) do
    cond do
      a == "" and b == "" -> ""
      String.contains?(a, "\n\n") or String.contains?(b, "\n\n") -> "\n\n"
      String.contains?(a, "\n") or String.contains?(b, "\n") -> "\n"
      true -> " "
    end
  end

  # Index from which the tail must be held back: trailing whitespace followed
  # by a partial open tag, either of which may complete into a span boundary
  # when the next chunk arrives.
  defp holdback_index(work) do
    keep = byte_size(work) - partial_open_len(work)
    count_trailing_ws(work, keep)
  end

  defp partial_open_len(work) do
    max = min(byte_size(work), byte_size(@open) - 1)

    Enum.find(max..1//-1, 0, fn len ->
      binary_part(work, byte_size(work) - len, len) == binary_part(@open, 0, len)
    end)
  end

  defp split_leading_ws(bin) do
    len = count_leading_ws(bin, 0)
    {binary_part(bin, 0, len), binary_part(bin, len, byte_size(bin) - len)}
  end

  defp count_leading_ws(bin, i) when i < byte_size(bin) do
    if :binary.at(bin, i) in @ws, do: count_leading_ws(bin, i + 1), else: i
  end

  defp count_leading_ws(_bin, i), do: i

  defp split_trailing_ws(bin) do
    cut = count_trailing_ws(bin, byte_size(bin))
    {binary_part(bin, 0, cut), binary_part(bin, cut, byte_size(bin) - cut)}
  end

  defp count_trailing_ws(bin, i) when i > 0 do
    if :binary.at(bin, i - 1) in @ws, do: count_trailing_ws(bin, i - 1), else: i
  end

  defp count_trailing_ws(_bin, i), do: i

  defp record_span(t, ""), do: {t, []}

  defp record_span(t, span) do
    if span in t.spans do
      {t, []}
    else
      {%{t | spans: [span | t.spans]}, [span]}
    end
  end

  defp record_spans(t, spans) do
    Enum.reduce(spans, {t, []}, fn span, {t, recorded} ->
      {t, new} = record_span(t, span)
      {t, recorded ++ new}
    end)
  end

  defp strip_block(%{type: "text", text: text} = block) when is_binary(text) do
    {clean, spans} = strip(text)
    {%{block | text: clean}, spans}
  end

  defp strip_block(%{"type" => "text", "text" => text} = block) when is_binary(text) do
    {clean, spans} = strip(text)
    {Map.put(block, "text", clean), spans}
  end

  defp strip_block(block), do: {block, []}

  defp empty_text_block?(%{type: "text", text: ""}), do: true
  defp empty_text_block?(%{"type" => "text", "text" => ""}), do: true
  defp empty_text_block?(_block), do: false
end
