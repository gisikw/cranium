## Goal

Call `Store.upsert_epoch` at the right points in the inference lifecycle so that the `epochs` DB row tracks `status`, `turn_count`, and `saturation` as inference runs.

## Context

- `Cranium.Store.Epoch` schema already has `status`, `turn_count`, `saturation`, `system_prompt`. Migration exists and is applied.
- `Cranium.Store.upsert_epoch/2` is implemented and tested (`store_test.exs:53`).
- `Cranium.Agent.infer/3` returns `{:ok, %{output, usage, ...}}` where `usage = %{input_tokens: N, output_tokens: N}` — `input_tokens` is the whole request context, the right proxy for context saturation.
- `Cranium.Epoch.handle_call({:submit, ...})` orchestrates the full inference cycle but currently makes zero `upsert_epoch` calls.
- Config `:pipeline` section has `saturation_warn_threshold: 50` and `saturation_bucket_size: 5` — saturation-related config lives here.
- The `Cranium.Epoch` struct does **not** currently track `turn_count` in process state. It must to avoid a read-before-upsert round trip.
- Per INVARIANTS.md: pure decision functions must be separated from I/O orchestration.
- `Cranium.Backend.LLM.Anthropic` uses `@default_model "claude-haiku-4-5-20251001"` and reads the active model from `Application.get_env(:cranium, :backends)[:anthropic_model]`. No existing context-window registry exists.
- `epoch_test.exs` already exists with a `clear/1` describe block; new tests should extend it.

## Approach

Add `turn_count: 0` to the `Cranium.Epoch` struct. On `init`, upsert the epoch row as `"active"` with `turn_count: 0`. On `{:submit, ...}`, upsert `"inferring"` before inference and `"active"` with updated `saturation` and incremented `turn_count` after. Add `max_context_tokens` to the `:pipeline` config (default 200_000) so the denominator is configurable per deployment without hardcoding. `compute_saturation/1` reads from config at call time and is defined as a public `def` with `@doc false` to enable direct unit testing.

## Tasks

1. **[config/config.exs]** — Add `max_context_tokens: 200_000` to the `config :cranium, :pipeline` block alongside the existing saturation tuning knobs.
   Verify: `mix compile --warnings-as-errors` passes.

2. **[lib/cranium/epoch.ex]** — Add `turn_count: 0` to the `defstruct` and add `turn_count: non_neg_integer()` to the `@type t` typespec.
   Verify: `mix compile --warnings-as-errors` passes.

3. **[lib/cranium/epoch.ex]** — Add `@doc false` public function `compute_saturation(usage)`. It reads `max_context_tokens` from `Application.get_env(:cranium, :pipeline)[:max_context_tokens]` (default 200_000) and returns `min(usage.input_tokens / max_context_tokens, 1.0)`. Add `@spec compute_saturation(map()) :: float()`.
   Verify: `Cranium.Epoch.compute_saturation(%{input_tokens: 200_000})` → `1.0`; `Cranium.Epoch.compute_saturation(%{input_tokens: 0})` → `0.0`.

4. **[lib/cranium/epoch.ex:init/1]** — After building `state`, call `Store.upsert_epoch(conversation_id, %{status: "active", turn_count: 0})` to create the DB row on epoch start.
   Verify: `mix test test/cranium/store_test.exs` still passes.

5. **[lib/cranium/epoch.ex:handle_call({:submit, ...})]** — Upsert `%{status: "inferring"}` immediately before calling `Cranium.Agent.infer`. After inference returns `{:ok, %{usage: usage}}`, compute saturation via `compute_saturation(usage)`, increment `state.turn_count`, upsert `%{status: "active", saturation: saturation, turn_count: new_count}`, and carry `new_count` in process state. On inference error, upsert `%{status: "active"}` without changing `turn_count`.
   Verify: `mix compile --warnings-as-errors` passes.

6. **[test/cranium/epoch_test.exs]** — Add two test blocks to the existing file:
   - A `describe "compute_saturation/1"` block with direct unit tests: midpoint (0.5), full (1.0), zero (0.0), and over-limit clamped to 1.0.
   - A `describe "submit/2 — saturation tracking"` integration test: start the epoch, mock `Cranium.Backend.LLM.Mock` to return `{:llm_usage, %{input_tokens: 100_000}}` then `{:llm_stop, "end_turn"}`, call `Epoch.submit/2`, then verify `Store.get_epoch/1` returns `saturation` ≈ 0.5 and `turn_count: 1` and `status: "active"`.
   Verify: `mix test test/cranium/epoch_test.exs` passes; `mix test --no-start` passes.

## Open Questions

None. All three prior open questions are resolved:
- `compute_saturation` is a public `def` with `@doc false` in `epoch.ex`.
- Epoch DB row is created in `init/1`.
- Saturation denominator is read from `Application.get_env(:cranium, :pipeline)[:max_context_tokens]` (configured in `config.exs`, default 200_000).
