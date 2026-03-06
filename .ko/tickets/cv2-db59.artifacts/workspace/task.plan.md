cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
The plan is at `.ko/tickets/cv2-db59.artifacts/plan.md`. Here's a summary:

**Goal:** Implement the chunked audio input protocol with a new `TakeRegistry` GenServer and three HTTP endpoints.

**New files:**
- `lib/cranium/input/take_registry.ex` — GenServer tracking open takes, buffering numbered chunks, detecting gaps on seal, assembling audio when complete
- `test/cranium/input/take_registry_test.exs` — unit tests (isolated named process per test)

**Modified files:**
- `lib/cranium/transport/http.ex` — add `POST /v1/input/start`, `PUT /v1/input/:id/:seq`, `POST /v1/input/:id/done`, plus a private `trigger_audio_inference/1` helper that mirrors the existing `/v1/submit` Task pattern
- `lib/cranium/application.ex` — add `TakeRegistry` to supervision tree
- `test/test_helper.exs` — start `TakeRegistry` singleton for tests
- `test/cranium/transport/http_test.exs` — new `describe "input protocol"` block

**3 open questions flagged:**
1. **`last_seq` in `/done` body** — required to detect trailing lost chunks; assumed yes, but needs confirmation
2. **Chunk Content-Type** — assumes `application/octet-stream`; needs confirmation of Hearth's actual format
3. **Take lifetime/cleanup** — no TTL eviction in scope, noted as follow-up
