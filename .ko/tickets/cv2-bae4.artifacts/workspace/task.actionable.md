cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at the plan artifact:

## Analysis

**Open Questions:** The plan explicitly lists 2 open questions:

1. **Duration in audio rendition** (lines 50-51) — Should the audio rendition omit `duration` entirely, include `null`, or require an `update_segment/3` API if the HTTP handler updates the manifest post-synthesis?

2. **Conversation_id source** (lines 52-53) — Should Manifest accept `conversation_id` on first `add_utterance` call, or use an explicit `init_stream(stream_id, conversation_id)` API?

These are real architectural decisions that affect the API surface and integration points with Egress and HTTP handlers.

**Completeness:** The plan is well-structured:
- ✓ Clear goal and context
- ✓ Three identified files with proper locations
- ✓ Ordered tasks with verification steps (compile, tests pass)
- ✓ API signatures, data structures, and JSON serialization approach all specified

**Feasibility:** All referenced patterns are plausible:
- File paths follow Elixir conventions (`lib/cranium/`, `test/cranium/`)
- GenServer pattern with named process in supervision tree is standard
- Test structure (`async: false`, Mox) matches described testing patterns
- README "Segment Manifest" section mentioned in context

The plan is complete and feasible, but the two open questions block implementation.

```json
{"disposition": "needs_input", "plan_questions": [{"id": "q1", "question": "Should the audio rendition include a `duration` field, and if so, how should it be populated before TTS synthesis completes?", "context": "The README shows `\"duration\": 1.2` on audio renditions, but audio is served lazily from TTS cache. Duration won't be known until synthesis finishes. If the manifest needs post-synthesis updates, an `update_segment/3` API would be required.", "options": [{"label": "Omit duration field (Recommended)", "value": "omit_duration", "description": "Audio renditions don't include duration initially; updated via API after TTS synthesis if needed"}, {"label": "Include duration as null", "value": "null_duration", "description": "Audio renditions include `\"duration\": null` initially, replaced with actual value after synthesis"}, {"label": "Add update API", "value": "update_api", "description": "Implement an explicit `update_segment/3` function to modify segments after creation"}]}, {"id": "q2", "question": "How should `conversation_id` be passed to the Manifest?", "context": "The ticket API signatures don't include `conversation_id` in `add_utterance/add_cue`. The plan assumes first-call initialization or nil default, but a cleaner design might use an explicit `init_stream` call that Egress invokes with metadata from `stream_metadata`.", "options": [{"label": "Explicit init_stream call (Recommended)", "value": "init_stream_api", "description": "Add `init_stream(stream_id, conversation_id)` for Egress to call on stream start"}, {"label": "Optional param on first call", "value": "first_call_param", "description": "Pass `conversation_id` to the first `add_utterance` call; no separate init"}, {"label": "Defaults to nil", "value": "nil_default", "description": "Conversation_id defaults to nil; no explicit initialization needed"}]}]}
```
