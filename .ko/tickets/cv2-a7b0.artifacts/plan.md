## Goal
Store the TurnInjector-enriched user message text in the database instead of the pre-injection raw text, so persisted history reflects the same content the LLM received.

## Context

**The bug** (epoch.ex:151–232):
- Line 156: `text = msg_map[:text] || ""` captures raw user text.
- Line 176: `Cranium.Context.process(normalized, pipeline_ctx)` runs the full pipeline including TurnInjector, which may prepend `<system-reminder>` blocks to `message[:text]`.
- Line 179: `Cranium.Store.append_message(..., %{role: :user, content: text})` stores the PRE-injection raw text.
- Lines 182–189: `enriched[:messages]` (which contains the post-injection current message) is passed to the Agent for inference — the injected content reaches the LLM but is never stored.

**TurnInjector** (context/turn_injector.ex:34–46):
- When injections fire, it updates `message[:text]` to `prefix <> "\n" <> original_text`.
- When no injections fire, it returns the message unchanged.
- Therefore `enriched[:text]` is always a valid string: either the raw text (no injections) or the enriched text (injections prepended).

**Secondary gap**: `pipeline_ctx` in epoch.ex (lines 167–174) has no `:epoch` key, so TurnInjector currently receives no epoch state and can never fire any injection. TurnInjector reads `context[:epoch][:saturation]`, `context[:epoch][:last_invoked_at]`, etc. The Store epoch schema has `saturation` and `updated_at` (which can proxy for last_invoked_at), but not `interrupted_context`, `last_reminder_bucket`, or `resume_breadcrumb`. Without fixing this gap, the persistence fix at line 179 has no visible effect in practice — the stored text would still equal the raw text because no injections fire.

**Conclusion**: The persistence fix and the pipeline_ctx gap are coupled. Both need to be addressed for the ticket to have any observable effect.

## Approach

1. Populate `pipeline_ctx[:epoch]` in epoch.ex with the stored epoch state fields relevant to TurnInjector (saturation, updated_at as last_invoked_at, and any available injection-related fields).
2. Change epoch.ex:179 to store `enriched[:text]` instead of `text`.
3. Add a test to epoch_test.exs that seeds a high-saturation epoch, submits a message, and asserts the stored message content contains the saturation `<system-reminder>` block.

## Tasks

1. **[lib/cranium/epoch.ex:167–174, handle_call :submit]** — Expand `pipeline_ctx` to include an `:epoch` key populated from `Cranium.Store.get_epoch`. Map `saturation` directly; map `updated_at` to `last_invoked_at` (only when the epoch has prior turns, i.e., `turn_count > 0`, to avoid spurious time-gap injection on a fresh epoch). This makes saturation injection and time-gap injection actually fire when conditions are met.
   Verify: existing epoch tests still pass; no new crashes.

2. **[lib/cranium/epoch.ex:179]** — Change the `append_message` call to use `enriched[:text]` instead of `text`. Since `enriched[:text]` is always set (TurnInjector either enriches or returns message unchanged), no fallback is needed; use `enriched[:text] || text` for safety.
   Verify: `mix test test/cranium/epoch_test.exs` passes.

3. **[test/cranium/epoch_test.exs]** — Add a test in a new `describe "submit/2 — injection persistence"` block that:
   - Pre-creates an epoch in the DB with `saturation: 51.0` (past the 50% threshold) and `turn_count: 1` using `Cranium.Store.update_epoch`.
   - Submits a message via `Cranium.Epoch.submit`.
   - Reads back stored messages via `Cranium.Store.get_messages`.
   - Asserts the user message content contains `<system-reminder>` with the saturation warning text.
   Verify: new test passes, all epoch tests pass.

## Open Questions

1. **`last_reminder_bucket` field**: TurnInjector's saturation injection uses `context[:epoch][:last_reminder_bucket]` for rising-edge detection. This field is not currently stored in the DB. Without it, the saturation injection will fire on every turn once saturation > 50%, not just on bucket crossings. Should `last_reminder_bucket` be added to the Store.Epoch schema and tracked after each turn that fires an injection? Or is repeated firing acceptable?

2. **`interrupted_context` and `resume_breadcrumb`**: These fields are read by TurnInjector but don't exist in the Store epoch schema or anywhere in the codebase. Are they in scope for this ticket, or deferred to a follow-on?

3. **`updated_at` as proxy for `last_invoked_at`**: The Store epoch's `updated_at` reflects the last `update_epoch` call (which happens after inference and after clear). Using it as `last_invoked_at` is a reasonable proxy. Confirm this is the intended behavior, or if a dedicated `last_invoked_at` field should be added to Store.Epoch.
