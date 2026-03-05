cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-271e.artifacts/plan.md`. Here's the summary:

**Key findings:**
- `Cranium.Backend.TTS.Kokoro` already exists and calls Req.post — only needs the default URL fixed (`localhost:8788` → `https://tts.gisi.network/synthesize`, confirmed from v1 `socket.go:415`) and a `:plug` option for test injection
- `Synthesizer` already calls the TTS backend but is missing a mode guard — it should only synthesize in `:voice` mode
- `Chunker` voice mode uses sentence boundaries with 75/20 word targets; needs replacement with paragraph boundaries (`\n\n`) and 30/100 thresholds matching v1's `ttsChunkBatch` algorithm

**7 tasks:**
1. Fix Kokoro URL default + add `plug:` passthrough for testability
2. Rewrite Chunker voice mode to paragraph-boundary with 30/100 thresholds
3. Add mode guard to Synthesizer (skip TTS in text mode)
4. `test/cranium/backend/kokoro_test.exs` — Req.Test mock HTTP tests
5. `test/cranium/egress/chunker_test.exs` — paragraph chunking unit tests
6. `test/cranium/egress/synthesizer_test.exs` — Mox-based synthesizer tests
7. Full suite green
