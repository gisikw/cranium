## Goal

Wire the Egress Synthesizer to the Kokoro TTS HTTP endpoint, change Chunker to paragraph-boundary splitting with 30-word first / 100-word subsequent thresholds, and add tests for both.

## Context

**What's already implemented (not stubs):**
- `lib/cranium/backend/tts.ex`: Defines `Cranium.Backend.TTS` behaviour AND contains `Cranium.Backend.TTS.Kokoro` which already calls `Req.post(url, json: %{text, voice, format})`. The default URL is wrong: `http://localhost:8788/synthesize` — should be `https://tts.gisi.network/synthesize` (confirmed from v1 `socket.go:415`).
- `lib/cranium/egress/synthesizer.ex`: Already calls `backend.synthesize(text, [])` and wraps results. **Missing mode guard** — it synthesizes in all modes, not just `:voice`.

**What needs to change:**
- `lib/cranium/egress/chunker.ex`: Voice mode currently splits on sentence boundaries (`[.!?]`) with 75/20 word targets. Ticket requires paragraph-boundary (`\n\n`) splitting with first=30 / rest=100 thresholds, matching v1 `ttsChunkBatch` in `socket.go:450-491`. The v1 algorithm: split on `\n\n`, filter empties, accumulate paragraphs until word count >= threshold, always flush remainder as final chunk.

**Testing infrastructure in place:**
- `test/support/mocks.ex`: `Cranium.Backend.TTS.Mock` (Mox) already defined.
- `config/test.exs`: Test env uses `Cranium.Backend.TTS.Mock` for `:tts` backend.
- Req `~> 0.5` supports `Req.Test` for HTTP mocking (pass `plug: {Req.Test, name}` to Req calls).

**V1 TTS endpoint (from `socket.go:415, 626-639`):**
```
POST https://tts.gisi.network/synthesize
Content-Type: application/json
{"text": "...", "voice": "af_heart", "format": "mp3"}
→ 200 OK, body: raw audio bytes
```

## Approach

1. Fix the Kokoro backend URL default and add `plug:` option passthrough for testability.
2. Rewrite the Chunker's voice mode to paragraph-boundary with 30/100 thresholds.
3. Add mode guard to Synthesizer so TTS only runs in `:voice` mode.
4. Add unit tests for Kokoro (Req.Test mock HTTP) and Chunker (paragraph splitting logic).

## Tasks

1. **[`lib/cranium/backend/tts.ex:Cranium.Backend.TTS.Kokoro`]** — Fix the default `tts_url` from `http://localhost:8788/synthesize` to `https://tts.gisi.network/synthesize`. Add `:plug` option support: `Keyword.get(opts, :plug)` and pass it to `Req.post(url, json: payload, plug: plug)` (omit the key if nil). This makes the backend testable with `Req.Test`.
   Verify: `mix compile --warnings-as-errors` passes.

2. **[`lib/cranium/egress/chunker.ex`]** — Replace voice mode logic:
   - Remove `@voice_target_words` and `@voice_min_words` module attributes.
   - Add `@voice_first_words 30` and `@voice_rest_words 100`.
   - Replace `chunk_text(text, :voice)` to split on `~r/\n\n+/`, filter blank paragraphs, then accumulate with the first-threshold/rest-threshold algorithm (matching v1 `ttsChunkBatch`): accumulate paragraphs until word count >= current threshold, emit batch, switch to rest threshold; always flush remainder as final chunk.
   - Remove or repurpose `chunk_by_word_count/3` (sentence-based helper no longer needed for voice mode).
   Verify: `mix compile --warnings-as-errors` passes.

3. **[`lib/cranium/egress/synthesizer.ex`]** — Add mode guard: only call `backend.synthesize/2` when `Map.get(context, :mode) == :voice`. In non-voice mode, pass text chunks through as `%{type: :text, data: text}` without TTS. Update the `@moduledoc` to reflect paragraph-chunk input (from Chunker).
   Verify: `mix compile --warnings-as-errors` passes.

4. **[`test/cranium/backend/kokoro_test.exs`]** — New test file for `Cranium.Backend.TTS.Kokoro`. Tests:
   - `synthesize/2` returns `{:ok, audio_binary}` when HTTP 200 with binary body (stub via `Req.Test.stub` + pass `plug: {Req.Test, CrainumKokoroTest}` in opts).
   - `synthesize/2` returns `{:error, {:http_error, 503, _}}` on non-200.
   - `synthesize/2` returns `{:error, _}` on connection error.
   Use `async: true`. No real HTTP calls.
   Verify: `mix test test/cranium/backend/kokoro_test.exs` passes.

5. **[`test/cranium/egress/chunker_test.exs`]** — New test file for `Cranium.Egress.Chunker`. Tests for voice mode:
   - Single paragraph under 30 words → emitted as one chunk (remainder flush).
   - Two paragraphs crossing 30-word threshold → first batch emitted, remainder flushed as second.
   - Enough paragraphs to cross 30 words (first) then 100 words (rest) → correct batching.
   - Empty paragraphs are filtered.
   - Text mode: splits on `\n\n`, filters blanks (existing behavior, confirm it still works).
   Use `async: true`.
   Verify: `mix test test/cranium/egress/chunker_test.exs` passes.

6. **[`test/cranium/egress/synthesizer_test.exs`]** — New test file for `Cranium.Egress.Synthesizer`. Tests (using `Cranium.Backend.TTS.Mock` via Mox):
   - In `:voice` mode, text chunk is synthesized → `%{type: :audio, data: binary, text: text}`.
   - In `:voice` mode, `%{type: :marker}` passes through unchanged.
   - In `:text` mode, text chunk passes through as `%{type: :text, data: text}` without calling backend.
   - TTS failure in voice mode falls back to `%{type: :text, data: text}`.
   Use `async: false` (Mox global expectations require it unless using `allow/3`).
   Verify: `mix test test/cranium/egress/synthesizer_test.exs` passes.

7. **Final** — Run full suite. Verify: `mix test` all green.

## Open Questions

None. The endpoint URL, request shape, and chunking algorithm are all confirmed from v1 source. The 30/100 word thresholds are specified in the ticket and match v1 `newTTSBatcher(b, ctx, roomID, 30, 100)`.
