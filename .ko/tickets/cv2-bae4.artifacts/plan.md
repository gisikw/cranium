## Goal

Implement `Cranium.Manifest` — a GenServer that tracks active stream segments and serializes the segment manifest JSON matching the README spec.

## Context

- README "Segment Manifest" section defines the exact JSON shape: `{stream_id, status, segments[]}` where segments are either `utterance` (with renditions map) or `cue` (with cue_type and data).
- Audio rendition URLs follow pattern `/v1/streams/:stream_id/segments/:index/audio`; text renditions `/v1/streams/:stream_id/segments/:index/text`.
- `Cranium.Stage` helpers (`init_stream/3`, `buffer_chunk/3`, `flush_buffer/2`) handle streaming buffers — Manifest is orthogonal to this, it's a separate registry GenServer.
- `Cranium.Application` supervision tree uses `rest_for_one`. Manifest should be added as a top-level child (ephemeral state, no persistence dependency needed).
- Testing pattern: pure-function tests are `async: true`, GenServer tests that share named processes are `async: false`. Mox is used for backend mocks. Test files live in `test/cranium/`.
- No HTTP transport yet — the ticket scope is the GenServer only. The segment text content is tracked so HTTP handlers can serve it later.
- The ticket says "audio rendition URL advertised but served lazily from TTS cache" — URL is always present in the manifest, actual audio serving is future scope.

## Approach

Implement `Cranium.Manifest` as a GenServer holding `%{stream_id => manifest_state}` in its state. Each `manifest_state` is a plain map with `:stream_id`, `:status`, `:conversation_id`, and `:segments` (list ordered by index). Expose five public API functions: `init_stream/2`, `add_utterance/3`, `add_cue/4`, `complete/1`, and `get/1`. `get/1` returns a JSON-serializable map built from the internal state. Audio renditions omit the `duration` field entirely. Add the GenServer to the supervision tree and write ExUnit tests covering all operations.

## Tasks

1. **[lib/cranium/manifest.ex] — Create `Cranium.Manifest` GenServer.**
   - Module-level state: `%{stream_id => manifest_state}` where `manifest_state = %{stream_id: string, status: :streaming | :complete, conversation_id: string | nil, segments: [segment]}`.
   - Segment structs: utterance = `%{index: n, type: :utterance, text: string}`, cue = `%{index: n, type: :cue, cue_type: string, data: map}`.
   - `init_stream(stream_id, conversation_id)` — creates a new manifest entry with status `:streaming` and empty segments. Egress calls this on stream start.
   - `add_utterance(stream_id, index, text)` — inserts utterance segment. If no manifest entry exists yet, creates one with `conversation_id: nil`.
   - `add_cue(stream_id, index, cue_type, data)` — inserts cue segment.
   - `complete(stream_id)` — sets status to `:complete`.
   - `get(stream_id)` — returns `{:ok, json_map}` or `{:error, :not_found}`.
   - JSON serialization: converts internal state to the README shape. Utterance renditions include both `text` and `audio` entries with their respective URL patterns (`url` and `mime` keys; no `duration`). Cue segments include `cue_type` and `data`. Status atoms become strings.
   - Segments are sorted by index in the output (insertion order may vary since add_utterance/add_cue can be called out of order).
   - No TTL/eviction in this ticket — ephemeral means process-lifetime only.
   - Verify: module compiles (`mix compile`).

2. **[lib/cranium/application.ex] — Add `Cranium.Manifest` to the supervision tree.**
   - Insert before or alongside `Cranium.Egress` (no ordering dependency between them).
   - Verify: `mix compile` and `iex -S mix` starts without errors.

3. **[test/cranium/manifest_test.exs] — Write ExUnit tests.**
   - `init_stream/2` creates manifest with correct conversation_id and empty segments.
   - `add_utterance/3` builds correct utterance segment with text and audio renditions.
   - `add_cue/4` builds correct cue segment with cue_type and data.
   - Segments from `get/1` are sorted by index even when added out of order.
   - `complete/1` sets status to `"complete"` in the JSON output.
   - `get/1` on unknown stream_id returns `{:error, :not_found}`.
   - `get/1` returns map matching README shape (stream_id string, status string, segments list with renditions for utterances).
   - Audio rendition includes `url` and `mime` but no `duration` field.
   - Use `async: false` since tests share the named GenServer process. Use `setup` to generate a fresh unique `stream_id` per test to avoid state leakage.
   - Verify: `mix test test/cranium/manifest_test.exs` passes.

## Open Questions

None.
