cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-a7b0.artifacts/plan.md`. Here's a summary:

**Root cause**: `epoch.ex:179` stores `text` (raw user input), but `enriched[:text]` (post-TurnInjector) contains any prepended `<system-reminder>` injections. The enriched text is passed to the LLM but discarded without persisting.

**Compounding issue**: `pipeline_ctx` in epoch.ex has no `:epoch` key, so TurnInjector currently receives no epoch state and cannot fire any injection at all. Fixing persistence alone has no visible effect until this gap is also fixed.

**Planned tasks**:
1. Expand `pipeline_ctx` in `epoch.ex` to include `epoch:` data from the stored epoch (saturation → saturation, updated_at → last_invoked_at when turn_count > 0).
2. Change epoch.ex:179 to use `enriched[:text]` instead of `text`.
3. Add a test that seeds a high-saturation epoch and verifies the stored message content includes the saturation `<system-reminder>` block.

**Three open questions** flagged in the plan:
1. Should `last_reminder_bucket` be added to the DB schema to prevent saturation injection firing on every turn?
2. Are `interrupted_context` and `resume_breadcrumb` in scope (they don't exist in the DB yet)?
3. Confirm `updated_at` as the proxy for `last_invoked_at`, or add a dedicated field?
