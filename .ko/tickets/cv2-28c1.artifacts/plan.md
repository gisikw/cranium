## Goal
Wire epoch state fields into the `pipeline_ctx` passed to `Cranium.Context.process/2` so TurnInjector's four conditional injections (time-gap, saturation, interrupted, resume) actually fire.

## Context

**The gap** (`epoch.ex:167-174`): `pipeline_ctx` is assembled with only `identity`, `projects_dir`, `mode`, `history_window`, `now`, and `epoch_id`. TurnInjector reads `context[:epoch]` which is never populated, so all four injection functions are dead code.

**TurnInjector** (`context/turn_injector.ex`): Reads `context[:epoch]` for:
- `last_invoked_at` — DateTime, triggers time-gap reminder if >30 min
- `saturation` — float treated as **0–100** percentage (threshold: 50, bucket: 5)
- `last_reminder_bucket` — int, rising-edge suppression for saturation warnings
- `interrupted_context` — string, set when previous invocation was cancelled
- `resume_breadcrumb` — string, set when process was restarted with existing epoch

**Saturation unit mismatch**: `compute_saturation/1` returns 0.0–1.0 (a fraction). TurnInjector treats `saturation` as 0–100. The DB stores the 0–1 value. Conversion (multiply by 100) must happen when building `pipeline_ctx`.

**DB schema** (`store/epoch.ex`): Has `saturation`, `updated_at`. No `interrupted_context` column — this must be added. `last_invoked_at` can be derived from the epoch record's `updated_at` (updated after every `update_epoch` call, which happens at the end of each inference). `last_reminder_bucket` and `resume_breadcrumb` are ephemeral (in-memory; lost on restart is acceptable).

**Epoch GenServer state struct**: Currently holds `conversation_id`, `epoch_id`, `transport`, `transport_meta`, `agent_pid`, `status`, `stream_id`, `turn_count`. Needs extension.

**Cancel flow**: `handle_cast(:cancel, ...)` sets process state to `:cancelled` but does not update the DB or store any interrupted context. The submit handler detects the result and resets state to `:idle` — this is where we should detect a cancelled turn and persist `interrupted_context`.

**Store tests** (`store_test.exs`) reference `upsert_epoch` and a 2-arg `append_message` — these are stale and already broken against the current implementation. Do not attempt to fix them in this ticket; note they will remain failing.

## Approach

1. Add `interrupted_context :text` (nullable) to the `epochs` DB table via migration, and add it to the Ecto schema and changeset.
2. Extend the `Cranium.Epoch` struct with `last_invoked_at`, `saturation`, `last_reminder_bucket`, `interrupted_context`, `resume_breadcrumb`, and `current_message_text` (for cancel capture). Populate these on `init` from the DB record and latest handoff.
3. In `handle_call({:submit, ...})`: populate `pipeline_ctx[:epoch]`, persist cleared `interrupted_context` after context assembly, update in-memory state fields after inference, and detect cancelled turns to persist `interrupted_context`.

## Tasks

1. **`priv/repo/migrations/<timestamp>_epoch_interrupted_context.exs`** — New migration: `alter table(:epochs)` to add `interrupted_context :text, null: true`. Follow the existing migration pattern (forward-only, no rollback).
   Verify: `mix ecto.migrate` runs without error.

2. **`lib/cranium/store/epoch.ex`** — Add `field :interrupted_context, :string` to the schema. Add `:interrupted_context` to the `cast/2` list in `changeset/2`.
   Verify: schema compiles; `mix test test/cranium/store_test.exs` unchanged.

3. **`lib/cranium/store.ex`** — In `epoch_to_map/1`, include `interrupted_context: e.interrupted_context`. No other changes; the existing `update_epoch` path already passes through arbitrary attrs via `Epoch.changeset`.
   Verify: `Cranium.Store.get_epoch/1` returns the new field.

4. **`lib/cranium/epoch.ex`** — Extend `defstruct` and `@type t` with:
   - `last_invoked_at: DateTime.t() | nil`
   - `saturation: float()` (default `0.0`, in 0–1 scale as stored)
   - `last_reminder_bucket: non_neg_integer()` (default `0`)
   - `interrupted_context: String.t() | nil`
   - `resume_breadcrumb: String.t() | nil`
   - `current_message_text: String.t() | nil` (scratch field for cancel capture)

   In `init/1`: when resuming an existing epoch, populate `last_invoked_at` from `epoch_record.updated_at`, `saturation` from `epoch_record.saturation`, `last_reminder_bucket` from `div(trunc(epoch_record.saturation * 100), 5) * 5`, `interrupted_context` from `epoch_record.interrupted_context`, and `resume_breadcrumb` from `Cranium.Store.get_latest_handoff/1` (use the content string if `{:ok, content}`, nil otherwise). On fresh epoch creation, all these are nil/0.

   In `handle_call({:submit, message}, ..., %{status: :idle} = state)`:
   - Store `msg_map[:text]` in `state.current_message_text` at the top.
   - After building `msg_map` but before calling `Cranium.Context.process/2`, build `pipeline_ctx[:epoch]`:
     ```
     epoch: %{
       last_invoked_at: state.last_invoked_at,
       saturation: state.saturation * 100.0,
       last_reminder_bucket: state.last_reminder_bucket,
       interrupted_context: state.interrupted_context,
       resume_breadcrumb: state.resume_breadcrumb
     }
     ```
   - After `Cranium.Context.process/2` returns (context assembled), clear one-shot fields: call `Cranium.Store.update_epoch(state.epoch_id, %{interrupted_context: nil})` and clear `resume_breadcrumb` from process state.
   - After successful inference (`{:ok, %{output: output, usage: usage}}`), update state:
     - `last_invoked_at: DateTime.utc_now()`
     - `saturation: saturation` (the 0–1 value)
     - `last_reminder_bucket: max(state.last_reminder_bucket, div(trunc(saturation * 100), 5) * 5)`
     - `interrupted_context: nil`
     - `resume_breadcrumb: nil`
     - `current_message_text: nil`
   - In the failing branch, also clear `current_message_text`.

   In `handle_call({:submit, ...})`, after inference, check if `state.status == :cancelled` before the state reset. If so, call `Cranium.Store.update_epoch(state.epoch_id, %{interrupted_context: state.current_message_text})` to persist what was being asked when cancelled.

   Verify: `mix test test/cranium/epoch_test.exs` passes.

5. **`test/cranium/epoch_test.exs`** — Add tests:
   - `"populates time-gap injection after 30+ minutes"`: submit a message on a resumed epoch whose DB record has `updated_at` >30 min ago; assert the enriched message text contains the `<system-reminder>` time-gap block.
   - `"populates interrupted_context injection after a cancel"`: submit, cancel mid-flight (via `Cranium.Epoch.cancel/1`), wait for submit to return, then submit again; assert the second submission's enriched message contains the interrupted injection.
   - `"clears interrupted_context from DB after injection"`: same setup; assert that after the second submit completes, `Store.get_epoch` shows `interrupted_context: nil`.
   - `"populates resume_breadcrumb from latest handoff on restart"`: save a handoff for a conversation, start a fresh epoch process for the same conversation_id pointing at the existing active DB epoch; assert `resume_breadcrumb` is populated and the first submission injects it.

   Verify: `mix test test/cranium/epoch_test.exs` — all new tests pass.

## Open Questions

1. **`interrupted_context` content**: This plan stores the user's message text that was in-flight when cancelled ("what they asked"). The TurnInjector injection says "Here's what you were working on" — which implies the *assistant's work in progress*, not the user's prompt. Should we instead capture partial streaming output from the agent, or is the user's message an acceptable proxy? If partial output is needed, that requires storing it as the agent streams, which is significantly more complex.

2. **`resume_breadcrumb` source**: The plan uses the latest handoff document (generated by `!clear`) as resume context. If no handoff exists (fresh conversation that was never cleared), `resume_breadcrumb` is nil and no injection fires. Is the latest handoff the right source, or should it be something else (e.g., last N messages of the epoch, a dedicated breadcrumb field)?
