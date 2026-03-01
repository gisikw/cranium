# Summary: crn-2e3e — Threaded audio transcript echo

## What was done

The transcript echo that previously posted as a standalone message in the main room timeline now posts as a **threaded reply** to the original audio event. This keeps the transcription visible but out of the main conversation flow.

### Changes

- **`matrix_helpers.go`** — Added `sendThreadReply(ctx, roomID, parentEventID, message)` method. It constructs a `MessageEventContent` identical to `sendMessage` and then calls `content.GetRelatesTo().SetThread(parentEventID, parentEventID)` before dispatching via `SendMessageEvent`. The `is_falling_back: true` semantics and `InReplyTo` fallback are handled automatically by mautrix's `SetThread`.

- **`handlers.go`** — One-line change: replaced `b.sendMessage(...)` with `b.sendThreadReply(ctx, roomID, evt.ID, ...)` in the audio transcription block.

- **`testutil_test.go`** — Added `ThreadParent id.EventID` to `sentMessage`. The mock's `SendMessageEvent` now populates this field when it detects `RelThread` in the content's `RelatesTo` (handled for both the value and pointer cases of `MessageEventContent`).

- **`handlers_test.go`** — Updated `TestBridge_HandleMessage_AudioEchoesTranscript` to assert `msgs[0].ThreadParent == evt.ID`. The existing body-format checks are retained.

- **`spec/message_routing.feature`** — Updated the scenario step to "echoed as a threaded reply to the audio message before agent dispatch".

## Notable decisions

- **No new helper abstraction needed.** `sendThreadReply` is a thin wrapper; it does not duplicate logic beyond the relation setup. Future use cases (e.g., threading other reply types) can reuse it.
- **`SetThread(parentEventID, parentEventID)` — same event for both args.** Per mautrix convention, when there is no prior thread head, the audio event itself acts as both the thread root and the `InReplyTo` fallback.

## All plan tasks completed

All five tasks from the plan were implemented exactly as specified. No deviations. No open questions materialized.

## Test status

`go test -tags goolm ./...` — all green.
