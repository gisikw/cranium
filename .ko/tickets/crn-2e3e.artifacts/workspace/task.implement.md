cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
All 5 tasks complete. Here's a summary:

**Task 1 — `spec/message_routing.feature`**
Updated the audio echo scenario step from "echoed as a blockquote before agent dispatch" to "echoed as a threaded reply to the audio message before agent dispatch".

**Task 2 — `matrix_helpers.go`**
Added `sendThreadReply(ctx, roomID, parentEventID, message)` method. It builds the same `MessageEventContent` as `sendMessage` then calls `content.GetRelatesTo().SetThread(parentEventID, parentEventID)` before sending, which sets `m.thread` with `is_falling_back: true` and an `m.in_reply_to` fallback.

**Task 3 — `handlers.go:89`**
Replaced `b.sendMessage(ctx, roomID, formatTranscriptEcho(transcription))` with `b.sendThreadReply(ctx, roomID, evt.ID, formatTranscriptEcho(transcription))`.

**Task 4 — `testutil_test.go`**
Added `ThreadParent id.EventID` to `sentMessage`. In `SendMessageEvent`, added detection of `RelThread` in both `event.MessageEventContent` and `*event.MessageEventContent` cases to populate `msg.ThreadParent`.

**Task 5 — `handlers_test.go`**
Updated `TestBridge_HandleMessage_AudioEchoesTranscript` to assert `msgs[0].ThreadParent == evt.ID`, verifying the echo is sent as a threaded reply to the original audio event.

No deviations from the plan.
