cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
All four tasks complete. Here's a summary:

---

## Summary

### Task 1 — `bridge.go`
Added `formatTranscriptEcho(transcription string) string` after `formatAudioPrompt`. The function splits the transcription on newlines, prefixes each line with `"> "`, and rejoins. For empty input it returns `"> "` (caller guards against empty).

### Task 2 — `handlers.go`
In the audio block, immediately after `transcribeAudio` succeeds, added:
```go
if transcription != "" {
    b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))
}
```
This fires before `message = formatAudioPrompt(...)` so the echo reaches the room before Claude is invoked.

### Task 3 — `bridge_test.go`
Added `TestFormatTranscriptEcho` covering three cases: single-line, multi-line (each line gets `"> "` prefix), and empty string (returns `"> "`; caller-guarded, behaviour documented).

### Task 4 — `handlers_test.go`
Added `TestBridge_HandleMessage_AudioEchoesTranscript` that spins up an `httptest.Server` returning `{"text": "Hello from voice"}`, sets `b.sttURL`, queues a Claude mock response, sends a `MsgAudio` event, and asserts the first message body starts with `"> "` and contains the transcription text.

No deviations from the plan.
