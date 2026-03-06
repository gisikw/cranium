cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Done. Summary of changes:

**`lib/cranium/backend/stt.ex`** — Fixed `Whisper.transcribe/2`:
- Switched from `application/octet-stream` raw body to `form_multipart: [file: {audio, filename: "audio", content_type: "application/octet-stream"}]`
- Added `plug:` opt passthrough for test injection (same pattern as Kokoro)
- Added `{"error": "..."}` response handling → `{:error, {:stt_error, reason}}`
- Default URL changed from `localhost:8787` to `https://stt.gisi.network/transcribe`

**`test/cranium/backend/whisper_test.exs`** — 5 tests covering: success, whitespace trimming, service error field, non-200 HTTP, transport error.
