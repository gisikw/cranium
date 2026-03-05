cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-bae4.artifacts/plan.md`.

**Summary:**

The ticket is straightforward — a new `Cranium.Manifest` GenServer with no upstream dependencies.

**Three tasks:**

1. **`lib/cranium/manifest.ex`** — GenServer holding `%{stream_id => manifest_state}`. Public API: `add_utterance/3`, `add_cue/4`, `complete/1`, `get/1`. `get/1` serializes to the README JSON shape (utterances get both text and audio rendition URLs; cues get `cue_type` + `data`; segments sorted by index).

2. **`lib/cranium/application.ex`** — Add `Cranium.Manifest` as a supervised child alongside the pipeline stages.

3. **`test/cranium/manifest_test.exs`** — `async: false` tests covering all operations, using unique stream IDs per test to avoid state collision.

**Two open questions flagged:**

1. **Audio rendition `duration`** — README shows `1.2` but duration isn't known at manifest-build time (TTS is lazy). Omit or null? Would need an `update_segment/3` call if it's to be filled in later.

2. **`conversation_id` sourcing** — The ticket's API signatures (`add_utterance(stream_id, index, text)`) don't include it. Should Egress call an explicit `init_stream(stream_id, conversation_id)` first, or does conversation_id arrive with the first `add_utterance` call?
