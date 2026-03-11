cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-190a.artifacts/plan.md`. Here's a summary:

**Goal:** Move handoff text from the `handoffs` table onto the epoch row itself, so history accrues per-epoch rather than being overwritten globally.

**Key findings:**
- The `epochs` table has a `unique_index(:conversations_id)` that must be dropped — it currently prevents multiple epoch rows per conversation (contradicting the goal)
- `HandoffWriter` already receives `epoch_id` as a parameter, so the write change is a one-liner
- `Store.get_latest_handoff` is replaced by a new `get_previous_epoch_handoff` that queries the most-recently-cleared epoch with a non-null handoff
- `PromptBuilder.resolve_handoff/1` and the `clear/1` epoch test are the only two call sites to update

**Two open questions flagged:**
1. Whether to drop the now-unused `handoffs` table in the same migration or a follow-up
2. Confirming that the "no previous cleared epoch" path (first-ever epoch) returns `:not_found` gracefully — it does, by design
