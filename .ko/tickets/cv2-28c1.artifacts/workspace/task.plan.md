cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-28c1.artifacts/plan.md`. Here's a summary:

## Goal
Wire epoch state into `pipeline_ctx[:epoch]` so TurnInjector's four injections actually fire.

## Key findings

- `pipeline_ctx` at `epoch.ex:167-174` never includes an `:epoch` key — TurnInjector reads `context[:epoch]` which is always nil
- **Saturation unit mismatch**: `compute_saturation/1` returns 0.0–1.0, but TurnInjector expects 0–100. Conversion (`* 100`) needed when building pipeline_ctx
- `last_invoked_at` can be derived from `updated_at` on the DB record — no migration needed for it
- `last_reminder_bucket` is ephemeral (in-memory, derivable from stored saturation on restart)
- `interrupted_context` needs a new DB column (migration + schema update)
- `resume_breadcrumb` can be sourced from the latest handoff document

## Tasks (5 total)
1. Migration adding `interrupted_context :text` to `epochs`
2. Update `Store.Epoch` schema + changeset
3. Update `Store.epoch_to_map` to include `interrupted_context`
4. Extend `Cranium.Epoch` struct + wire all fields in `init`, `handle_call({:submit})`, and `handle_cast(:cancel)`
5. Add epoch integration tests for all four injections

## Open questions (flagged in plan)
1. What should `interrupted_context` capture — the user's message text (simple) or partial agent output (complex)?
2. Is the latest handoff document the right source for `resume_breadcrumb`, or something else?
