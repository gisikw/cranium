---
id: cv2-ac16
status: closed
deps: []
created: 2026-03-06T12:43:03Z
type: task
priority: 2
---
# Epoch lifecycle: wire !clear to trigger handoff generation via Effects

## Notes

**2026-03-06 13:19:37 UTC:** # Summary: cv2-ac16 — Wire !clear to handoff generation

## What was done

1. **`lib/cranium/epoch.ex`** — Removed the two TODO comment lines in `handle_call(:clear)` and replaced them with the live call `Cranium.Effects.generate_handoff(state.conversation_id)`. Exactly as planned.

2. **`test/cranium/epoch_test.exs`** — New integration test created. Sets up Store, Registry, DynamicSupervisor, and Task.Supervisor (Effects.Supervisor). Configures the LLM mock to emit `{:llm_text, "handoff content"}` + `{:llm_stop, "end_turn"}`, calls `Epoch.clear/1`, waits for the handoff task process to exit (via monitor), then asserts `Store.get_latest_handoff/1` returns the expected content. Test passes.

## Notable decisions

- Test uses `CraniumTest.DataCase` (the existing Ecto sandbox case), consistent with other Ecto-touching tests.
- Module name is `Cranium.EpochTest` (not `CraniumTest.EpochTest`). INVARIANTS.md says the latter, but the codebase majority uses the former pattern. No action taken — this is a pre-existing inconsistency across test files, not introduced by this change.
- `async: false` + `set_mox_global` used correctly since shared state (Store, Registry) is involved.

## Invariant check

No violations. The `generate_handoff` call is fire-and-forget (async Task), consistent with the "Effects run as supervised Tasks — crash isolation from main pipeline" invariant. No blocking in `handle_call`. No secrets. No scope creep.

**2026-03-06 13:19:37 UTC:** ko: SUCCEED
