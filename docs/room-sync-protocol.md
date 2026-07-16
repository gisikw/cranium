# Cranium Room Sync Protocol

> Protocol reference for Hearth and future native clients.
> Base URL: `https://cranium.gisi.network` (or local dev equivalent)

## Overview

Room sync replaces the patchwork of manifest polling, firehose SSE, and metadata fetches with a single coherent API. The model is:

1. **Boot**: Fetch the room list, then snapshot a room to get current state + transcript + cursor
2. **Subscribe**: Open an SSE event stream with the cursor to receive live updates
3. **Send**: POST messages or audio takes as commands; rendering comes from the event stream
4. **Reconnect**: Re-fetch snapshot (cursor recovery) or resume the event stream with last cursor

This is deliberately NOT Matrix — no federation, no E2EE, no state resolution, no room auth DAGs.

---

## Authentication

All endpoints require authentication. Currently single-tenant; auth mechanism is orthogonal to this protocol.

---

## Timestamps

All timestamps in this protocol are ISO 8601 UTC with second precision (e.g. `2026-06-29T04:30:00Z`). No sub-second component is emitted; ordering is carried by `seq` (events) and array order (transcripts), never by timestamp.

---

## Endpoints

### Room List

```
GET /v1/rooms
```

Returns all rooms sorted by latest activity (most recent first).

**Response** `200 OK`
```json
[
  {
    "id": "cranium",
    "name": "cranium",
    "description": "Summary text from landscape...",
    "last_activity_at": "2026-06-29T04:30:00Z",
    "latest_message_preview": "Hi there, how can I help?",
    "latest_message_at": "2026-06-29T04:30:00Z",
    "has_active_turn": false,
    "unread": true,
    "last_read_seq": 138
  }
]
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Room identifier (conversation_id) |
| `name` | string | Display name (currently same as id) |
| `description` | string? | Landscape summary |
| `last_activity_at` | ISO 8601? | From landscape |
| `latest_message_preview` | string? | Truncated text of most recent non-orientation message (≤120 chars) |
| `latest_message_at` | ISO 8601? | Timestamp of that message |
| `has_active_turn` | boolean | Whether inference is currently running |
| `unread` | boolean | `true` when the room has non-orientation messages newer than its read marker — or any messages at all if the room has never been marked read. See Read Marker. |
| `last_read_seq` | integer? | Event seq the read marker points at; `null` if the room has never been marked read |

**Polling**: Hearth should poll this on foreground transitions. A global activity SSE stream is planned but deferred.

---

### Room Snapshot

```
GET /v1/rooms/:room_id/snapshot
```

Returns the full current state of a room: metadata, epoch state, recent transcript, active turn info, and a cursor for event stream subscription.

**Response** `200 OK`
```json
{
  "room": {
    "id": "cranium",
    "title": "cranium"
  },
  "state": {
    "epoch_id": "a1b2c3d4-...",
    "saturation": 0.42,
    "turn_count": 7,
    "handoff_generating": false,
    "active_turn": null,
    "profile": "exo-tiamat"
  },
  "recent_transcript": [ /* TranscriptMessage[] — see below */ ],
  "cursor": {
    "room_id": "cranium",
    "seq": 142
  },
  "has_more": true
}
```

**`state.saturation`** — context window usage as a 0..1 fraction. This is the canonical scale everywhere saturation appears in this protocol (snapshot, `turn.completed`, `context.saturation.updated`).

**`state.active_turn`** — when inference is running:
```json
{
  "stream_id": "strm_abc123",
  "conversation_id": "cranium",
  "started_at": "2026-06-29T04:31:00Z",
  "accumulated_text": "Here's what I think about...",
  "accumulated_parts": [
    {"id": "tmp:0", "type": "text", "text": "Here's what I think about..."}
  ],
  "pending_tool_calls": [
    {"id": "tool_xyz", "name": "mcp__tiamat__bash", "input": {"command": "ls"}}
  ]
}
```

This is how reconnecting clients recover mid-turn state without replaying ephemeral events.

**`cursor`** — treat as opaque. Store it and present it on event stream subscription. The cursor is fetched AFTER state assembly to guarantee no events are missed.

**`has_more`** — `true` if older messages exist beyond the 50 returned. Use the transcript endpoint for scrollback.

---

### Transcript Scrollback

```
GET /v1/rooms/:room_id/transcript?before=:message_id&limit=:n
```

Paginated transcript for scrollback. Also supports `after=:message_id` for forward pagination.

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `before` | UUID | — | Fetch messages older than this message ID |
| `after` | UUID | — | Fetch messages newer than this message ID |
| `limit` | int | 50 | Max 200 |

**Response** `200 OK`
```json
{
  "messages": [ /* TranscriptMessage[] */ ],
  "has_more": true
}
```

---

### TranscriptMessage Shape

Both snapshot and transcript endpoints return messages in this shape:

```json
{
  "id": "a1b2c3d4-...",
  "room_id": "cranium",
  "role": "assistant",
  "parts": [
    {"id": "a1b2c3d4:0", "type": "text", "text": "Hello!"},
    {
      "id": "a1b2c3d4:1",
      "type": "tool_call",
      "tool": "mcp__tiamat__bash",
      "input": {"command": "echo hi"},
      "status": "complete"
    },
    {
      "id": "a1b2c3d4:2",
      "type": "tool_result",
      "tool_use_id": "tool_abc",
      "content": "hi\n",
      "is_error": false
    }
  ],
  "text": "Hello!",
  "origin": "hearth",
  "created_at": "2026-06-29T04:30:00Z",
  "epoch_id": "e1f2g3h4-...",
  "parent_id": null,
  "provenance": { /* optional */ },
  "usage": { /* optional */ }
}
```

**Part types:**

| Type | Fields | Notes |
|------|--------|-------|
| `text` | `text` | Plain text content |
| `tool_call` | `tool`, `input`, `status`, `summary?` | Status: `pending`, `running`, `complete`, `error` |
| `tool_result` | `tool_use_id`, `content`, `is_error` | Result of a tool call |
| `image` | `media_type`, `source` | Source is `"base64"` or `"url"` |
| `status` | `text` | System status messages |

Part IDs are deterministic (`{message_id}:{index}`) — the same content block produces the same part ID whether received live or loaded from history.

Tool-result-only user messages (intermediate CC turns) are folded into their corresponding tool_call's status and excluded from the projected transcript.

---

### Event Stream

```
GET /v1/rooms/:room_id/events?since=:cursor_seq
```

Resumable SSE stream. The `since` parameter is the `cursor.seq` from a snapshot or the last received durable event seq.

**Connection lifecycle:**
1. Server subscribes to internal events BEFORE reading from DB (gap-free guarantee)
2. Catchup: any durable events with seq > since are sent immediately
3. Live: new events are forwarded as they occur
4. Keepalive: `: keepalive\n\n` comments every 30s to prevent proxy timeouts

**Cursor expired**: If `since` is older than the oldest available event (events have been purged), the server sends a `cursor_expired` event and closes. The client must re-fetch the snapshot.

```
event: cursor_expired
data: {"type":"cursor_expired","room_id":"cranium","seq":null,"occurred_at":"...","payload":{"refresh":true}}
```

#### Durable Events (persisted, replayable)

These have an integer `seq` and are used as the SSE `id`. They represent state transitions.

```
id: 143
event: message.created
data: {"event_id":"...","room_id":"cranium","seq":143,"type":"message.created","occurred_at":"...","payload":{...}}
```

**Durable event types:**

| Type | Payload | When |
|------|---------|------|
| `turn.started` | `stream_id`, `epoch_id` | Inference begins |
| `turn.completed` | `stream_id`, `epoch_id`, `turn_count`, `saturation` | Inference finishes. `saturation` is a 0..1 fraction |
| `turn.cancelled` | `stream_id` | Turn cancelled |
| `turn.errored` | `stream_id`, `epoch_id`, `error` | Turn failed. `error` is a human-readable string (≤500 chars), `null` when no detail is available |
| `message.created` | `message_id`, `message`, `role`, `origin`, `epoch_id`, `preview` | Message persisted. `message` is the full TranscriptMessage projection (see above); `preview` is the first 200 chars of the message text, omitted when empty |
| `room.state.updated` | Varies | Room state changed |
| `room.epoch.cleared` | `old_epoch_id` | Epoch cleared |
| `room.epoch.created` | `epoch_id` | New epoch started |
| `handoff.started` | `epoch_id` | Handoff generation begins |
| `handoff.completed` | `epoch_id` | Handoff generation done |
| `context.saturation.updated` | `saturation` | Context window usage changed. `saturation` is a 0..1 fraction |

#### Ephemeral Events (NOT persisted, live rendering only)

These have `seq: null` and no SSE `id`. They are for real-time rendering during active turns. **Do not depend on replaying these after reconnect** — use the enriched `active_turn` in the snapshot instead.

```
event: turn.delta
data: {"type":"turn.delta","room_id":"cranium","seq":null,"occurred_at":"...","payload":{"content":"Hello "}}
```

| Type | Payload | Notes |
|------|---------|-------|
| `turn.delta` | `content` (string) | Text chunk during streaming |
| `turn.tool_use` | `id`, `name`, `input` | Tool call started |
| `turn.tool_result` | `tool_use_id`, `content`, `is_error` | Tool call completed |
| `turn.segment` | `stream_id`, `index`, `text`, `renditions` | A playout-ready utterance segment. `renditions` lists available formats (`["text"]` or `["text","audio"]`). Audio is served lazily at `/v1/streams/:stream_id/segments/:index/audio`. |
| `turn.cue` | `stream_id`, `index`, `cue_type`, `data` | A positional marker (e.g. show-image-here) emitted mid-stream. |

#### Client Deduplication

Events are delivered **at-least-once**, not exactly-once. If a race between catchup replay and live subscription delivers the same event twice, deduplicate by `event_id`. Ephemeral events (seq: null) don't need dedup — rendering them twice is harmless.

**Clients MUST ignore unknown event types.** Cranium may add new types without a version bump.

---

### Send Message

```
POST /v1/rooms/:room_id/messages
Content-Type: application/json
```

```json
{
  "text": "Hello!",
  "origin": "hearth",
  "profile": "exo-tiamat",
  "disposition": "conversational"
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `text` | string | Yes (or images) | Message text |
| `origin` | string | No | Client identifier |
| `profile` | string | No | Override default router profile |
| `model` | string | No | Override model selection |
| `disposition` | string | No | `"conversational"` (default), `"silent"`, `"raw"` |
| `ephemeral` | boolean | No | If true, message is not persisted |
| `depth` | int | No | Max agentic depth |

**Response** `202 Accepted`
```json
{
  "stream_id": "strm_abc123"
}
```

The command response is a boring acknowledgement. The canonical rendering comes from the event stream (`message.created` for the user message, then `turn.started`, ephemeral deltas, `turn.completed`, and `message.created` for the assistant response).

**Response** `400 Bad Request` — if text is empty and no images attached.

**Response** `503 Service Unavailable` — server is draining (graceful shutdown).

---

### Send Audio Take

```
POST /v1/rooms/:room_id/audio-takes
Content-Type: application/json
```

```json
{
  "origin": "hearth",
  "profile": "exo-tiamat",
  "disposition": "conversational"
}
```

Opens a chunked audio take. Audio segments are then uploaded to the segment registry using the returned `take_id`.

**Response** `200 OK`
```json
{
  "take_id": "take_abc123",
  "stream_id": "strm_def456"
}
```

Audio pipeline details (segment upload, transcription flow) are outside the scope of this protocol doc — they follow the existing media pipeline.

---

### Cancel Turn

```
POST /v1/rooms/:room_id/cancel
```

Cancels the active inference turn for the room.

**Response** `200 OK`
```json
{
  "command": "cancel"
}
```

Always returns 200 regardless of whether a turn was active. If a turn was running, a `turn.cancelled` event will appear on the event stream.

---

### Read Marker

```
POST /v1/rooms/:room_id/read-marker
Content-Type: application/json
```

Advances the room's read marker — the client tells the server "I've seen through this point." Single-tenant: one marker per room, shared across all clients (marking read on Hearth clears the badge on Lair).

```json
{
  "seq": 142
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `seq` | integer | No | The event seq the client has read through — the `cursor.seq` from the snapshot, or the seq of the last durable event received on the SSE stream. Omit (or send `{}`) to mark read through the room's latest event. |

**Response** `200 OK`
```json
{
  "room_id": "cranium",
  "last_read_seq": 142
}
```

The response is the resulting marker, which is not always the requested position:

- **Clamping**: `seq` beyond the room's latest event seq is clamped to the latest.
- **Monotonic**: the marker never moves backwards. Marking read at a seq at or below the current marker is a no-op that returns the existing marker. Stale or duplicate marks are safe.
- A `seq` older than the event retention window (the event has been purged) is treated as marking the room read through the present.

**Response** `400 Bad Request` — if `seq` is present but not a non-negative integer.

**Unread derivation**: a room's `unread` flag in the room list is `true` when its latest non-orientation message is newer than the read marker's position. A room that has never been marked read is `unread` as soon as it has any non-orientation message. Derivation is anchored to the permanent message history, so `unread` stays correct even after room events age out of the retention window.

No durable event is emitted when the marker moves; other clients pick up the new marker by re-fetching `GET /v1/rooms` (the same foreground-transition polling used for the rest of the room list).

**When to mark read**: mark read when the user views the room's transcript — on room entry, and as new messages arrive while the room is visibly focused. Send the cursor seq you actually hold; don't invent one.

---

## Client Lifecycle

### Boot

```
1. GET /v1/rooms                              → room list for sidebar
2. GET /v1/rooms/:room_id/snapshot            → state + transcript + cursor
3. GET /v1/rooms/:room_id/events?since=cursor → SSE subscription
4. POST /v1/rooms/:room_id/read-marker        → {"seq": cursor.seq} once the transcript is on screen
```

### Send a Message

```
1. POST /v1/rooms/:room_id/messages           → 202 with stream_id
2. Wait for events on the SSE stream:
   - message.created (user message)
   - turn.started
   - turn.delta, turn.delta, ...              (ephemeral — render live)
   - turn.tool_use                            (ephemeral — show tool indicator)
   - turn.tool_result                         (ephemeral — show result)
   - turn.completed
   - message.created (assistant message)
```

### Audio Playout

When the turn's disposition includes `"audio"`, the same event stream also
carries playout-ready segments. This replaces the old manifest-polling loop:

```
1. POST /v1/rooms/:room_id/messages (or /audio-takes)  → 202 with stream_id
2. Wait for events on the SSE stream:
   - turn.started
   - turn.segment (index 0)                   (ephemeral — fetch/play audio)
   - turn.cue                                  (ephemeral — positional marker)
   - turn.segment (index 1) ...
   - turn.completed
3. For each turn.segment, if "audio" in renditions, GET
   /v1/streams/:stream_id/segments/:index/audio to fetch the rendition.
   Segments are ordered by index; play in order.
```

Segments are ephemeral (`seq: null`). On reconnect mid-turn, recover the
segment list from the manifest endpoint rather than replaying the stream —
the audio renditions themselves are served lazily and remain fetchable by
`stream_id`/`index` for the manifest TTL.

### Reconnect

```
If SSE connection drops:

1. GET /v1/rooms/:room_id/events?since=last_cursor
   - If server sends events: apply them, resume live loop
   - If server sends cursor_expired: go to step 2

2. GET /v1/rooms/:room_id/snapshot            → full state recovery
   - If active_turn is present: render accumulated state, resume SSE
   - If no active_turn: render transcript, resume SSE
```

### Scrollback

```
User scrolls up past loaded transcript:

1. GET /v1/rooms/:room_id/transcript?before=oldest_message_id&limit=50
2. Prepend messages to transcript
3. If has_more: false, disable further scrollback
```

---

## Deferred Features

These are specced in the allium but not yet implemented:

| Feature | Status | Notes |
|---------|--------|-------|
| Global activity stream (`GET /v1/activity`) | Deferred | Poll `/v1/rooms` on foreground transitions for now |
| Command idempotency (`client_command_id`) | Deferred | Duplicate messages possible on flaky networks |

Read markers, formerly listed here, are specified above (see Read Marker).

---

## Event Taxonomy Reference

### Three-Tier Model

| Tier | Persisted | Replayable | seq | Purpose |
|------|-----------|------------|-----|---------|
| **Durable** | Yes | Yes | integer | State transitions |
| **Ephemeral** | No | No | null | Live rendering |
| **Snapshot recovery** | N/A | N/A | N/A | `active_turn` in snapshot for reconnect |

The split is load-bearing: intermediate messages (tool call/result pairs during a CC turn) are not persisted until `end_turn`. Durable mid-turn events would reference DB rows that don't exist yet. Ephemeral events avoid this structural problem while giving clients real-time rendering.

---

## SSE Wire Format

Standard SSE ([spec](https://html.spec.whatwg.org/multipage/server-sent-events.html)).

**Durable event:**
```
id: 143
event: message.created
data: {"event_id":"evt_...","room_id":"cranium","seq":143,"type":"message.created","occurred_at":"2026-06-29T04:30:00Z","correlation_id":null,"payload":{"message_id":"a1b2c3d4-...","role":"user","preview":"Hello","message":{ /* TranscriptMessage */ }}}

```

**Ephemeral event:**
```
event: turn.delta
data: {"type":"turn.delta","room_id":"cranium","seq":null,"occurred_at":"2026-06-29T04:30:01Z","payload":{"content":"I think "}}

```

**Keepalive:**
```
: keepalive

```

**Cursor expired:**
```
event: cursor_expired
data: {"type":"cursor_expired","room_id":"cranium","seq":null,"occurred_at":"...","payload":{"refresh":true}}

```

Note: each SSE block ends with a blank line (`\n\n`).
