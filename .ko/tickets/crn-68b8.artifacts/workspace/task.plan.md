cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
Plan written to `.ko/tickets/crn-68b8.artifacts/plan.md`. Here's the summary:

**Goal**: Echo the transcription as a Markdown blockquote to the room immediately after STT succeeds, before forwarding to Claude.

**Key files**:
- `bridge.go` — add `formatTranscriptEcho(transcription string) string` (prefixes each line with `> `)
- `handlers.go:88` — call `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))` after transcription succeeds
- `bridge_test.go` — unit test for the formatter
- `handlers_test.go` — integration test using `httptest.Server` to mock the STT endpoint

**Assumptions captured**:
- Empty transcriptions skip the echo (avoid emitting a lone `> `)
- Uses `sendMessage` (MsgText + HTML rendering) so the `> ` renders as a proper `<blockquote>` in Matrix clients — consistent with the ticket's "Markdown quote block" wording
