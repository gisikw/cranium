## Goal

Call `Store.upsert_epoch` at the right points in the inference lifecycle so that the `epochs` DB row tracks `status`, `turn_count`, and `saturation` as inference runs.

## Context

- `Cranium.Store.Epoch` schema already has `status`, `turn_count`, `saturation`, `system_prompt`. Migration exists and is applied.
- `Cranium.Store.upsert_epoch/2` is implemented and tested (`store_test.exs:53`).
- `Cranium.Agent.infer/3` returns `{:ok, %{output, usage, ...}}` where `usage = %{input_tokens: N, output_tokens: N}` — `input_tokens` is the whole request context, the right proxy for context saturation.
- `Cranium.Epoch.handle_call({:submit, ...})` orchestrates the full inference cycle but currently makes zero `upsert_epoch` calls.
- Config has `saturation_warn_threshold: 50` and `saturation_bucket_size: 5` (pipeline section) — these are future tuning knobs; this ticket only does tracking.
- The `Cranium.Epoch` struct does **not** currently track `turn_count` in process state. It must to avoid a read-before-upsert round trip.
- Per INVARIANTS.md: pure decision functions must be separated from I/O orchestration.

## Approach

Add `turn_count: 0` to the `Cranium.Epoch` struct. On `init`, upsert the epoch row as `"active"`. On `{:submit, ...}`, upsert `"inferring"` before inference and `"active"` with updated `saturation` and incremented `turn_count` after. Compute saturation as a private pure function: `input_tokens / @max_context_tokens`, clamped to 1.0. Use the Haiku/Sonnet/Opus shared limit of 200,000 tokens as the constant.

## Tasks

1. **[lib/cranium/epoch.ex]** — Add `turn_count: 0` to the `defstruct` and update the `@type t` typespec to include `turn_count: non_neg_integer()`.
   Verify: `mix compile --warnings-as-errors` passes.

2. **[lib/cranium/epoch.ex:init/1]** — After building `state`, call `Store.upsert_epoch(conversation_id, %{status: "active", turn_count: 0})` to create the DB row on epoch start.
   Verify: `mix test test/cranium/store_test.exs` still passes.

3. **[lib/cranium/epoch.ex:handle_call({:submit, ...})]** — Upsert `%{status: "inferring"}` immediately before calling `Cranium.Agent.infer`. After inference returns `{:ok, %{usage: usage}}`, compute saturation, increment `state.turn_count`, upsert `%{status: "active", saturation: saturation, turn_count: new_count}`, and update the process state with the new turn_count. On inference error, upsert `%{status: "active"}` without changing turn_count.
   Verify: `mix compile --warnings-as-errors` passes.

4. **[lib/cranium/epoch.ex]** — Add private pure function `compute_saturation(usage)` with module attribute `@max_context_tokens 200_000`. Returns `min(input_tokens / max, 1.0)`. Add typespec.
   Verify: function is callable, `compute_saturation(%{input_tokens: 200_000})` → 1.0, `compute_saturation(%{input_tokens: 0})` → 0.0.

5. **[test/cranium/epoch_test.exs]** — New test file. Test `compute_saturation/1` directly (if it's accessible via `Cranium.Epoch` — if private, test indirectly via integration). Add an integration test that starts `Cranium.Store`, calls `Store.upsert_epoch` to seed a row, then verifies saturation is written correctly after inference. Alternatively, test the saturation formula as a public function or expose it via a `@doc false` public wrapper for testability.
   Verify: `mix test test/cranium/epoch_test.exs` passes; `mix test --no-start` passes.

## Open Questions

1. **`compute_saturation` visibility**: INVARIANTS.md says pure decision functions get unit tests. `compute_saturation` is private in the current design — should it be a public function in a dedicated `Cranium.Epoch.Saturation` step module, or is a `defp` in `epoch.ex` acceptable for a one-liner formula? A step module adds a file for minimal logic; a `defp` is untestable in isolation. Preference would make this a `def` (not `defp`) in `epoch.ex` marked `@doc false`, allowing direct unit testing without the overhead of a new module.

2. **`upsert_epoch` in `init` vs. lazy**: Should the epoch row be created on process start (`init/1`) or only on first submit? Creating on init means the DB always has a row whenever an epoch process exists, which makes `get_epoch` reliable for external readers. Creating lazily keeps init lighter. Current plan: create on init.

3. **Saturation denominator**: 200,000 tokens covers all current Claude models. If the backend model is configurable, the denominator ideally reads from context (the model's actual limit). For now, a hardcoded constant avoids the complexity of model introspection. Flag if this assumption needs revisiting.
