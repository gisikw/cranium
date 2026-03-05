cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-ede0.artifacts/plan.md`. Here's the summary:

**What I found**: Both `transcriber.ex` and `stt.ex` already have substantial implementation — this isn't a from-scratch task. The issues are:

1. **Wrong request format**: Current code sends `application/octet-stream`. V1 Go source (`stt.go`) shows the endpoint expects **multipart/form-data** with field name `file`.
2. **Wrong default URL**: Points to `localhost:8787` instead of `https://stt.gisi.network/transcribe`.
3. **No testability**: Missing `plug:` opt passthrough (required for `Req.Test.stub` — Kokoro has it, Whisper doesn't).
4. **Missing error field**: V1 checks `response.error` in JSON; current Elixir ignores it.
5. **No tests**.

**Tasks**:
1. Fix `Cranium.Backend.STT.Whisper.transcribe/2` — multipart body, correct URL, `plug:` opt, error field handling
2. Add `test/cranium/backend/whisper_test.exs` — 5 tests covering success, whitespace trimming, service error, HTTP error, transport error

**One open question remains**: Does the endpoint care about the filename in the multipart `file` field, or will any placeholder (e.g. `"audio"`) work?
