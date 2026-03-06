# Summary: Epoch lifecycle saturation tracking

## What was done

All six planned tasks were completed:

1. **config/config.exs** — Added `max_context_tokens: 200_000` to the `:pipeline` config block.

2. **epoch.ex defstruct/typespec** — Added `turn_count: 0` field and `turn_count: non_neg_integer()` to `@type t`.

3. **compute_saturation/1** — Public `def` with `@doc false` and `@spec`. Reads `max_context_tokens` from config at call time (defaults to 200_000), returns `min(input_tokens / max_context_tokens, 1.0)`.

4. **init/1** — Calls `Store.upsert_epoch(conversation_id, %{status: "active", turn_count: 0})` immediately after building state, ensuring a DB row exists for every live epoch process.

5. **handle_call({:submit, ...})** — Upserts `"inferring"` before `Agent.infer`. On `{:ok, %{output, usage}}`, computes saturation, increments `turn_count`, upserts `%{status: "active", saturation: ..., turn_count: ...}`, and carries the new count in process state. On any error, upserts `%{status: "active"}` without touching `turn_count`.

6. **epoch_test.exs** — Added `describe "compute_saturation/1"` (four unit tests: zero, midpoint, full, over-limit clamp) and `describe "submit/2 — saturation tracking"` (integration test using Mox to inject mock LLM usage, then asserting DB row has `saturation: 0.5`, `turn_count: 1`, `status: "active"`). All 6 epoch tests pass.

## Notable decisions

- The `result` pattern match was extended from `{:ok, %{output: output}}` to `{:ok, %{output: output, usage: usage}}` to extract usage data — this is a safe refinement since `usage` was already present in the return value.
- The `output != ""` guard was moved inside the success branch rather than the outer `case`, preserving the same semantic while allowing the `saturation` upsert to happen even when output is empty.

## Pre-existing issue

`store_test.exs` has one pre-existing failure (`save_handoff/get_latest_handoff returns the latest handoff when multiple exist`) that is unrelated to this ticket and was present before any changes.
