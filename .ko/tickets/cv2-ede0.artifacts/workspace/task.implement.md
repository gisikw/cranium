cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
All 5 tests pass. Both tasks from the plan were already completed in a previous build attempt:

**Task 1** (`lib/cranium/backend/stt.ex`) — Already implemented correctly:
- Multipart form-data with `form_multipart: [file: {audio, filename: "audio", content_type: "application/octet-stream"}]`
- Default URL `https://stt.gisi.network/transcribe`
- `plug:` opt passthrough for test injection
- Handles `{"error": "..."}` response → `{:error, {:stt_error, reason}}`
- Trims whitespace from transcription

**Task 2** (`test/cranium/backend/whisper_test.exs`) — Already exists with all 5 tests: success, whitespace trimming, service error field, non-200 HTTP, and transport error. All pass.

No deviations from the plan. No changes needed — the previous build attempt completed the implementation successfully.
