## Goal
After a voice message is transcribed, echo the transcript to the room as a Markdown blockquote before forwarding it to Claude.

## Context
The audio handling path lives in `handlers.go:69-88`. After `transcribeAudio` succeeds, `message` is set to `formatAudioPrompt(transcription, caption)` and then passed to `invokeClaude`. There is currently no echo step.

`sendMessage` (in `matrix_helpers.go:48`) renders Markdown to HTML via goldmark and sets `Format: event.FormatHTML`, so a `> ` prefixed string will render as a proper `<blockquote>` in Matrix clients.

`formatAudioPrompt` and `formatImagePrompt` are pure functions in `bridge.go` with unit tests in `bridge_test.go`. The same pattern should be followed for the new `formatTranscriptEcho` helper.

`transcribeAudio` is a package-level function in `stt.go` that makes a real HTTP request. Integration tests that exercise the full audio path can spin up an `httptest.Server` to mock the STT response without requiring structural changes to `Bridge`.

## Approach
Add a pure `formatTranscriptEcho(transcription string) string` function that prefixes each line of the transcription with `> ` to form a Markdown blockquote. In the audio block of `handleMessage`, call `b.sendMessage` with this formatted string immediately after `transcribeAudio` succeeds and before setting `message`. Add a unit test for the formatter and an integration test using `httptest.Server` to mock the STT service.

## Tasks
1. [bridge.go] — Add `formatTranscriptEcho(transcription string) string` after `formatAudioPrompt`. It should split the transcription on newlines, prefix each line with `> `, and join them back. This produces a valid Markdown blockquote that `sendMessage` will render as `<blockquote>`.
   Verify: `go test ./...` passes.

2. [handlers.go:88] — After `transcribeAudio` succeeds (after the `if err != nil` block on line 83), insert `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))` before the `message = formatAudioPrompt(...)` line.
   Verify: `go test ./...` passes.

3. [bridge_test.go] — Add `TestFormatTranscriptEcho` covering: single-line transcription, multi-line transcription (verify each line gets `> ` prefix), and empty string (produces `> ` or empty, whichever is chosen — document the behaviour).
   Verify: new test passes.

4. [handlers_test.go] — Add `TestBridge_HandleMessage_AudioEchoesTranscript` that:
   - Spins up an `httptest.Server` returning `{"text": "Hello from voice"}`.
   - Sets `b.sttURL` to the test server URL.
   - Queues a Claude mock response.
   - Constructs a `MsgAudio` event (inline `makeEvent` variant with `MsgType: event.MsgAudio` and a fake `mxc://` URL).
   - Calls `b.handleMessage`.
   - Asserts that `mc.getMessages()` contains a message whose body starts with `> ` (the echo) before the Claude response.
   Verify: new test passes, existing tests unbroken.

## Open Questions
1. **Empty transcription**: if STT returns `{"text": ""}`, should `formatTranscriptEcho` emit `> ` (an empty blockquote) or should `handleMessage` skip the echo? Emitting `> ` is visually odd; skipping it is more defensive. Assuming: skip the echo when transcription is empty (guard with `if transcription != ""`).

2. **MsgType for the echo**: `sendMessage` sends `MsgText` (with HTML rendering). `sendNotice` sends `MsgNotice` (no Markdown rendering, no notification). Since the ticket explicitly calls for a "Markdown quote block", `sendMessage` is the right call — the `>` will render as a visual blockquote. Assuming `sendMessage`.
