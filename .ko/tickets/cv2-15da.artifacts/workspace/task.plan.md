cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan updated. Here's a summary of what changed from the prior version:

**All 3 open questions are now resolved:**

1. **`compute_saturation` visibility** → Public `def` with `@doc false` in `epoch.ex` — enables direct unit testing without a separate module.

2. **When to create the DB row** → `init/1` — a row exists whenever an epoch process exists, making `get_epoch` reliable for external readers.

3. **Saturation denominator** → Read from `Application.get_env(:cranium, :pipeline)[:max_context_tokens]` at runtime. This means adding `max_context_tokens: 200_000` to the `:pipeline` config in `config.exs` instead of a hardcoded module attribute. Operators can override it per deployment, and tests can set it via `Application.put_env`.

**Tasks restructured (6 steps):**
1. Add `max_context_tokens` to `config.exs`
2. Add `turn_count: 0` to struct + typespec
3. Add `compute_saturation/1` as `@doc false` public function reading from config
4. Call `upsert_epoch` in `init/1`
5. Wire `"inferring"`/`"active"` upserts around inference in `handle_call`
6. Extend existing `epoch_test.exs` with unit tests for `compute_saturation` and an integration test verifying saturation is persisted after submit
