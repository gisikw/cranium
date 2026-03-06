cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
All 6 tasks complete. 126 tests, 0 failures.

---

## Summary

**Task 1 — `config/config.exs`**: Added `max_context_tokens: 200_000` to the `:pipeline` config block.

**Task 2 — `lib/cranium/epoch.ex` struct**: Added `turn_count: 0` to `defstruct` and `turn_count: non_neg_integer()` to `@type t`.

**Task 3 — `lib/cranium/epoch.ex` compute_saturation**: Added `@doc false` public function `compute_saturation/1` with `@spec`. Reads `max_context_tokens` from config (default 200_000) and returns `min(input_tokens / max, 1.0)`.

**Task 4 — `lib/cranium/epoch.ex` init/1**: Added `Store.upsert_epoch(conversation_id, %{status: "active", turn_count: 0})` after building state.

**Task 5 — `lib/cranium/epoch.ex` handle_call**: Added `upsert_epoch(%{status: "inferring"})` before `Agent.infer`. After inference: on success, computes saturation, increments `turn_count`, upserts `%{status: "active", saturation: ..., turn_count: ...}`, carries new count in state. On error, upserts `%{status: "active"}` without changing `turn_count`.

**Task 6 — `test/cranium/epoch_test.exs`**: Added `describe "compute_saturation/1"` with 4 unit tests (zero, midpoint, full, over-limit). Added `describe "submit/2 — saturation tracking"` integration test verifying `saturation == 0.5`, `turn_count == 1`, `status == "active"` after a mocked inference with 100_000 input tokens.

No deviations from the plan. `Manifest` and `Egress` were already globally started in `test_helper.exs`, so no nested setup was needed in the integration test describe block.
