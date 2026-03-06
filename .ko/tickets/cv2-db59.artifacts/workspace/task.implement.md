cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
142 tests, 1 failure — the only failure is the pre-existing `StoreTest.save_handoff` flake (confirmed present before my changes).

---

## Summary

All 6 tasks implemented as specified:

**Task 1 — `lib/cranium/input/take_registry.ex`**
New GenServer with `Take` nested struct. State holds `takes` map and `ttl_ms`. Public API: `open/5`, `put_chunk/4`, `seal/3` — all accept `name:` opt for test isolation. Completeness check via `MapSet.difference`. TTL eviction via periodic `{:cleanup, ttl_ms}` message in `handle_info`. All typespecs included.

**Task 2 — `lib/cranium/application.ex`**
Added `Cranium.Input.TakeRegistry` after `Cranium.TTS.Cache`, before pipeline stages. Compiles clean with `--warnings-as-errors`.

**Task 3 — `test/test_helper.exs`**
Added `Cranium.Input.TakeRegistry.start_link(name: Cranium.Input.TakeRegistry)` so HTTP tests use the global singleton.

**Task 4 — `lib/cranium/transport/http.ex`**
Added three routes (`POST /v1/input/start`, `PUT /v1/input/:id/:seq`, `POST /v1/input/:id/done`) and private `trigger_audio_inference/1` helper that runs STT → Epoch.submit, with same error handling pattern as `/v1/submit`.

**Task 5 — `test/cranium/input/take_registry_test.exs`**
10 unit tests covering all spec'd cases, `async: true`, isolated named processes per test. All pass.

**Task 6 — `test/cranium/transport/http_test.exs`**
Added `describe "input protocol"` block with 6 tests. Uses `Map.put(:body_params, ...)` to bypass `Plug.Parsers` (works because Parsers skips already-fetched `body_params`). All pass.

**No deviations from the plan.**
