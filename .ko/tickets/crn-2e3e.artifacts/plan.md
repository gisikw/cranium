## Goal
Post the audio transcription echo as a threaded reply on the audio message instead of a standalone message in the main room timeline.

## Context

The audio transcription echo is currently handled in `handlers.go:69–91`. When an audio message
arrives and transcription succeeds, `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))`
posts the blockquote directly into the main conversation. The ticket asks that this be a
**threaded reply** to the original audio event, so the echo lives in the thread view and
doesn't clutter the main timeline.

mautrix provides `RelThread` (`m.thread`) in `event.RelatesTo`. Setting a thread relation requires:
- `Type: RelThread`
- `EventID`: the parent (audio) event ID
- `IsFallingBack: true` + `InReplyTo` fallback for clients without thread support

The helper method `(*RelatesTo).SetThread(mxid, fallback id.EventID)` handles this. It needs to be
set on the `MessageEventContent.RelatesTo` field before sending.

Key files:
- `handlers.go` — audio block calls `b.sendMessage` for the echo; needs to call a new `sendThreadReply`
- `matrix_helpers.go` — home for the new `sendThreadReply` method (currently 147 lines, well within 500-line limit)
- `spec/message_routing.feature` — spec scenario for audio echo needs updating
- `handlers_test.go` — `TestBridge_HandleMessage_AudioEchoesTranscript` verifies the echo; needs updating
- `testutil_test.go` — `sentMessage` struct and `SendMessageEvent` mock need to capture the thread parent

`formatTranscriptEcho` (in `bridge.go`) formats the transcription text; its output is unchanged —
only the delivery mechanism changes.

## Approach

Add a `sendThreadReply` method to `matrix_helpers.go` that constructs a `MessageEventContent` with
`RelatesTo.SetThread(parentEventID, parentEventID)` and calls `SendMessageEvent`. In `handlers.go`,
replace the `sendMessage` call for the transcript echo with `sendThreadReply(ctx, roomID, evt.ID, ...)`.
Update the spec, the mock's `sentMessage` struct to track the thread parent, and the test to assert
a thread relation is present.

## Tasks

1. **[spec/message_routing.feature]** — Update the "An audio message is transcribed and forwarded to Claude"
   scenario. Change "echoed as a blockquote before agent dispatch" to "echoed as a threaded reply to the
   audio message before agent dispatch".
   Verify: spec accurately describes the new behavior.

2. **[matrix_helpers.go]** — Add `sendThreadReply(ctx context.Context, roomID id.RoomID, parentEventID id.EventID, message string) id.EventID`.
   Construct a `MessageEventContent` with `MsgType`, `Body`, `Format`, `FormattedBody` (same as `sendMessage`),
   then call `content.GetRelatesTo().SetThread(parentEventID, parentEventID)` before sending.
   Verify: compiles without error.

3. **[handlers.go:89]** — In the audio block, replace `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))`
   with `b.sendThreadReply(ctx, roomID, evt.ID, formatTranscriptEcho(transcription))`.
   Verify: `go build -tags goolm ./...` passes.

4. **[testutil_test.go]** — Add a `ThreadParent id.EventID` field to `sentMessage`. In `SendMessageEvent`,
   detect `RelThread` in the content's `RelatesTo` and populate `msg.ThreadParent` with `RelatesTo.EventID`.
   Verify: existing tests still compile and pass.

5. **[handlers_test.go:TestBridge_HandleMessage_AudioEchoesTranscript]** — Update the test to assert that
   the first message (the echo) has `ThreadParent == evt.ID` (the audio event ID), rather than only checking
   the `"> "` prefix. Also verify the thread parent is the audio event's ID specifically.
   Verify: `just test` (or `go test -tags goolm ./...`) passes including this test.

## Open Questions

None. The Matrix threading API (`m.thread` with `is_falling_back: true`) is the standard approach for
thread-anchored messages, and mautrix's `SetThread` method is already used in the ecosystem for exactly
this pattern.
