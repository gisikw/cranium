cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Done. 54/54 tests pass. Here's what changed:

**Task 1 — `lib/cranium/backend/tts.ex`**
- Fixed default URL from `http://localhost:8788/synthesize` → `https://tts.gisi.network/synthesize`
- Added `:plug` option passthrough so tests can inject `{Req.Test, name}` without real HTTP

**Task 2 — `lib/cranium/egress/chunker.ex`**
- Replaced sentence-boundary voice logic (`@voice_target_words 75 / @voice_min_words 20`) with paragraph-boundary logic (`@voice_first_words 30 / @voice_rest_words 100`)
- New `chunk_by_paragraph/3` accumulates paragraphs until word count ≥ threshold, switches to 100-word threshold after first emit, always flushes remainder

**Task 3 — `lib/cranium/egress/synthesizer.ex`**
- Added mode guard: only calls `backend.synthesize/2` when `mode == :voice`; other modes pass text through as `%{type: :text, data: text}`

**Task 4 — `test/cranium/backend/kokoro_test.exs`** (new)
- 3 tests: 200 success, 503 error, connection error via `Req.Test.transport_error/2`

**Task 5 — `test/cranium/egress/chunker_test.exs`** (new)
- 11 tests covering: under-threshold remainder flush, paragraph accumulation, 30→100 threshold switching, empty paragraph filtering, text mode splitting, marker passthrough

**Task 6 — `test/cranium/egress/synthesizer_test.exs`** (new)
- 5 Mox-based tests: voice synthesis, voice marker passthrough, TTS failure fallback, text mode passthrough, text mode marker

**Deviation from plan:** Added `{:plug, "~> 1.14", only: :test}` to `mix.exs`. The plan called for `Req.Test` with the `plug:` option but didn't account for Plug being absent from the project. Plug is Req.Test's required backing library — without it, Req.Test.stub/2 doesn't work. Added as test-only dependency.
