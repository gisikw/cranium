# Plan: STT Integration — Wire Ingress Transcriber to stt.gisi.network

## Goal
Implement `Cranium.Backend.STT.Whisper` with the correct multipart request shape, testability via `Req.Test`, and add tests for it.

## Context

Both `lib/cranium/backend/stt.ex` and `lib/cranium/ingress/transcriber.ex` are already substantially implemented — this is **not** a stub situation. What's wrong:

- **Request format**: Current Whisper sends `application/octet-stream` raw binary. V1 Go source (`~/Projects/cranium/stt.go`) shows the endpoint expects **multipart/form-data** with a field named `file`.
- **Default URL**: Current default is `http://localhost:8787/transcribe`. Should be `https://stt.gisi.network/transcribe` (matching v1 config and TTS pattern).
- **Testability**: No `plug:` opt support. The Kokoro backend passes `plug: Keyword.get(opts, :plug)` through to `Req.post/2`, which is how `Req.Test.stub` works in tests. Whisper needs the same.
- **Error field**: V1 checks `result.Error` in the JSON response. Current Elixir only handles `{"text": "..."}` success case.
- **No tests**: `test/cranium/backend/` has `kokoro_test.exs` as the pattern to follow; no `whisper_test.exs` exists.

The transcriber routing logic (audio → STT → text passthrough) is already correct.

## Approach

Fix `Cranium.Backend.STT.Whisper.transcribe/2` in `lib/cranium/backend/stt.ex` to:
1. Build a multipart form-data body with field `file` containing the audio binary
2. Use the correct default URL
3. Accept `plug:` opt for test injection
4. Handle `{"error": "..."}` in the JSON response

Then write `test/cranium/backend/whisper_test.exs` following the Kokoro test pattern.

## Tasks

1. **[lib/cranium/backend/stt.ex:Cranium.Backend.STT.Whisper]** — Rewrite `transcribe/2`:
   - Accept `plug:` opt (same pattern as Kokoro: `plug = Keyword.get(opts, :plug)`)
   - Build multipart form-data body using Req's `:form_multipart` option (confirmed in `req ~> 0.5`): `form_multipart: [file: {audio, filename: "audio", content_type: "application/octet-stream"}]`
   - Change default URL to `https://stt.gisi.network/transcribe`
   - On 200: parse JSON, return `{:ok, text}` from `body["text"]`, or `{:error, {:stt_error, body["error"]}}` if `body["error"]` is non-nil
   - On non-200: `{:error, {:http_error, status, body}}`
   - On transport error: `{:error, reason}`
   Verify: `mix compile` clean.

2. **[test/cranium/backend/whisper_test.exs]** — New test file:
   - Use `Req.Test.stub` pattern from `kokoro_test.exs`
   - Test: 200 with `{"text": "hello"}` → `{:ok, "hello"}`
   - Test: 200 with `{"text": "  trimmed  "}` → `{:ok, "trimmed"}` (trim whitespace like v1 returns)
   - Test: 200 with `{"error": "bad audio"}` → `{:error, {:stt_error, "bad audio"}}`
   - Test: non-200 (503) → `{:error, {:http_error, 503, _}}`
   - Test: transport error (`:econnrefused`) → `{:error, _}`
   Verify: `mix test test/cranium/backend/whisper_test.exs` passes.

## Open Questions

1. **Multipart field name**: V1 uses `"file"` as the form field name with the filename derived from the file path. For the v2 API (in-memory binary), the filename will need a placeholder (e.g. `"audio.ogg"` or `"audio"`). Is there a specific filename the endpoint expects, or is any value acceptable?

2. **Audio format assumption**: The endpoint likely returns plain text or JSON. V1 parses JSON `{"text": "..."}`. The current Elixir code also expects JSON. If the endpoint ever returns plain text, `Req` will not auto-parse it. Assuming JSON is correct based on v1.

3. **Req multipart support**: Confirmed — `req ~> 0.5` supports `:form_multipart` with `[field: {binary, filename: "name", content_type: "..."}]` tuple syntax. No extra deps needed.
