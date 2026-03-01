cranium dev shell
  just test    — run tests
  just build   — build binary
  just deploy  — build + upgrade
Plan written to `.ko/tickets/crn-2e3e.artifacts/plan.md`. Here's the summary:

---

**Goal:** Post the audio transcription echo as a `m.thread` threaded reply on the original audio message, instead of a standalone message in the main room timeline.

**What I found:**
- The echo currently uses `b.sendMessage(...)` in `handlers.go:89`, posting directly into the main conversation
- mautrix already has `RelThread` and `(*RelatesTo).SetThread(parentEventID, fallback)` — no new dependencies needed
- The `formatTranscriptEcho` function is unchanged; only where the message is delivered changes

**Tasks (5):**
1. Update `spec/message_routing.feature` — change "echoed as a blockquote" to "echoed as a threaded reply"
2. Add `sendThreadReply(...)` to `matrix_helpers.go` — same as `sendMessage` but sets `RelatesTo.SetThread(parentEventID, parentEventID)`
3. In `handlers.go`, swap `sendMessage` → `sendThreadReply` with `evt.ID` as the thread parent
4. In `testutil_test.go`, add `ThreadParent` field to `sentMessage` and detect `RelThread` in the mock
5. Update `TestBridge_HandleMessage_AudioEchoesTranscript` in `handlers_test.go` to assert a thread relation is set

No open questions — the approach is straightforward with what mautrix already provides.
