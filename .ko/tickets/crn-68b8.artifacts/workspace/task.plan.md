cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
The plan is updated. Both open questions are now resolved:

- **Empty transcriptions**: skip the echo (confirmed by ticket author)
- **MsgType**: `sendMessage` (required by the Markdown blockquote requirement)

The plan is ready to implement. The 4 tasks are:

1. **`bridge.go`** — Add `formatTranscriptEcho(transcription string) string` after `formatAudioPrompt`
2. **`handlers.go:88`** — Call `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))` after STT succeeds (guarded by `if transcription != ""`)
3. **`bridge_test.go`** — Unit test `TestFormatTranscriptEcho` (single-line, multi-line, empty)
4. **`handlers_test.go`** — Integration test `TestBridge_HandleMessage_AudioEchoesTranscript` with `httptest.Server` mocking STT
