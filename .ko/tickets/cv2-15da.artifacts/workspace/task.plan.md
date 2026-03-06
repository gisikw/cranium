cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-15da.artifacts/plan.md`. Here's the summary:

**Goal:** Call `Store.upsert_epoch` at the right lifecycle points in `Cranium.Epoch` so the DB row tracks `status`, `turn_count`, and `saturation`.

**Key findings:**
- Schema and `upsert_epoch` are already implemented — no migrations needed
- `Agent.infer` returns `usage.input_tokens` which is the right saturation proxy
- `Cranium.Epoch` currently makes zero `upsert_epoch` calls

**4 code changes + 1 test:**
1. Add `turn_count: 0` to `Cranium.Epoch` struct
2. Upsert `status: "active"` on epoch `init`
3. Upsert `"inferring"` before inference, then `"active"` + saturation + turn_count after
4. Add private pure `compute_saturation/1` with `@max_context_tokens 200_000`
5. New `epoch_test.exs` covering the saturation formula and integration

**3 open questions** around `compute_saturation` visibility (private vs. public for testability), init vs. lazy row creation, and whether the 200k token constant should be model-aware.
