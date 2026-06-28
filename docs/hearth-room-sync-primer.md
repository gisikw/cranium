# Hearth room sync primer

This document captures the design conversation that led to a proposed first-party Cranium room sync API for Hearth. It is intentionally a primer, not a final spec. The goal is to give the Cranium-side agent enough context to design APIs that actually unblock Hearth instead of merely tidying existing endpoints.

## Problem statement

Hearth is becoming the native iOS client for Cranium/Maw-style interaction. From Hearth's perspective, Cranium is not primarily "an inference orchestrator"; it is the backing service for a chat-like room UI where the active room has durable scrollback, live assistant turns, audio/media lifecycle, tool render state, context saturation, and cross-room activity summaries.

Today Hearth interacts with several Cranium mechanisms that overlap but are not isomorphic:

- history/transcript fetch for prior messages;
- media submit path that returns a stream/manifest to poll;
- conversation/event SSE firehose for live events;
- metadata fetches for room state such as saturation;
- legacy Matrix/Headjack paths in the broader system.

This has already produced edge cases:

- live inference renders as multiple conversational text blocks while historical reconstruction often collapses prior assistant turns into one text blob;
- app suspend/resume can miss live events if the client was not connected at the right moment;
- Hearth has to reconcile separate lifecycles for transcript events, manifest segments, response completion, and metadata;
- planned Hearth features like tool-call rendering, context saturation, jump-to-bottom/unreads, and background robustness all depend on a cleaner synchronization contract.

The desired direction is **not** to deepen Hearth's dependence on the current legacy firehose. The current firehose is essentially a nosy GenServer / legacy bridge shape and can remain KTLO while Matrix/Headjack are phased out. The new work should define a first-party Cranium room sync model for agent-native conversations.

## North star

Cranium should expose a small, first-party room sync API for Hearth-native conversations:

> Commands produce durable events; durable projections serve product state; snapshots include cursors; recent events make clients resumable.

This is deliberately **not** "reinvent Matrix" in the broad sense. We do not want federation, E2EE protocol design, room auth DAGs, generic third-party client semantics, or state-resolution complexity. We do want the small useful subset of a room/event/sync model that Hearth needs:

- single-tenant rooms;
- durable ordered room events;
- resumable client sync after mobile suspend/reconnect;
- transcript projection with ordered renderable parts;
- active turn state;
- structured tool/audio/artifact events;
- room list summaries/global activity;
- clean separation between canonical server state and Hearth-local UI state.

## Key architectural stance

Avoid treating `history`, `manifest polling`, and `SSE firehose` as separate truths. Hearth should have one canonical sync story.

At the same time, do not take "event log is source of truth" so literally that scrollback requires replaying all events from year zero. The practical model should be:

- append-only/durable events provide causality, replay, debugging, and projection repair;
- materialized projections are canonical serving state for product reads;
- snapshots/projections carry an `as_of` cursor so clients can resume without gaps;
- replay has a reasonable horizon, after which the server tells clients to refresh a snapshot.

A transcript projection is not a disposable cache. It is durable serving state with lineage/provenance back to events where useful.

## Hearth's concrete needs

The API design should unblock these Hearth needs.

### 1. Boot/open active room without races

Hearth needs to open a room and receive:

- room metadata;
- recent transcript/messages in renderable shape;
- current active turn state, if any;
- context state such as saturation/turn count/handoff state;
- a cursor that represents the snapshot's consistency point.

Then Hearth should subscribe to events **after that cursor**. There must be no gap between snapshot and event stream.

Sketch:

```http
GET /v1/rooms/:room_id/snapshot
```

Response includes:

```json
{
  "room": { "id": "hearth", "title": "hearth" },
  "state": {
    "active_turn": null,
    "saturation": 0.51,
    "turn_count": 42,
    "handoff_generating": false
  },
  "recent_transcript": [],
  "cursor": "evt_..."
}
```

### 2. Resume after suspend/reconnect

Hearth is a mobile app. It can be suspended, killed, lose network, or switch rooms. It must be able to reconnect with the last applied cursor and catch up.

Sketch:

```http
GET /v1/rooms/:room_id/events?since=evt_...
```

If the cursor is still within replay horizon, Cranium replays missed events and continues streaming.

If too old, Cranium returns an explicit `cursor_too_old`/refresh instruction. Silent loss is unacceptable.

Invariant:

> A client with snapshot cursor `C` can either replay events after `C` or be told to refresh snapshot; it must never silently miss canonical room state.

### 3. Render live and historical turns the same way

Current Hearth behavior differs between live turns and historical reconstruction. Live streaming appends separate assistant text segment messages, while history often gives a collapsed `text` string. The new model should preserve ordered content parts.

Transcript/message shape should support renderable parts such as:

- text;
- tool call;
- tool result / tool completion status;
- audio segment references;
- artifact references;
- system/status markers if intended for UI.

Sketch:

```json
{
  "id": "msg_123",
  "room_id": "hearth",
  "role": "assistant",
  "created_at": "...",
  "origin": "inference",
  "parts": [
    { "id": "part_1", "type": "text", "text": "Yep —" },
    {
      "id": "part_2",
      "type": "tool_call",
      "tool": "functions.bash",
      "status": "complete",
      "summary": "ko ready"
    },
    { "id": "part_3", "type": "text", "text": "here's the inventory." }
  ],
  "source_event_id": "evt_..."
}
```

Plain `text` may remain as a convenience projection/preview, but it should not be the only durable representation.

### 4. Support detailed active-room events

The active room stream should be detailed enough for Hearth to render incremental state without bespoke polling for every subsystem.

Likely event categories:

- `message.created`
- `message.part.appended`
- `message.part.updated` or tool status transition
- `turn.started`
- `turn.updated`
- `turn.completed`
- `turn.cancelled`
- `audio.segment.available`
- `artifact.available`
- `room.state.updated`
- `context.updated`
- `handoff.started`
- `handoff.completed`

The exact names are less important than making the event envelope and projection semantics stable.

### 5. Support global/cross-room summaries

Hearth mostly cares about the active room in detail, but it also needs high-level information for inactive rooms:

- room created/deleted/renamed;
- latest message preview/time changed;
- unread count/read marker changed;
- active turn/activity indicator changed;
- maybe error/attention state.

This can be a global room-summary stream or a room-list snapshot plus replayable summary events.

Do not make Hearth subscribe to every detailed event for every room merely to show a room list.

### 6. Keep command responses boring

Hearth can optimistically render a user's message, but canonical rendering should come from events/projections.

Command endpoints should acknowledge acceptance and return ids/cursors/correlation data, not require the client to treat the response as the authoritative render payload.

Examples:

- send text message;
- submit audio take;
- cancel active turn;
- mark room read;
- create/switch/update room.

Important invariant for mobile/failover:

> A client command may be retried after timeout or failover with the same `client_command_id`; Cranium must either return the original accepted command/derived cursor or accept it exactly once.

### 7. Clarify server-canonical vs Hearth-local state

Server-canonical / Cranium-owned:

- rooms/conversations;
- transcript/messages/parts;
- assistant turn lifecycle;
- tool calls/results;
- audio/artifact availability;
- context saturation/turn count/handoff state;
- room latest activity;
- read markers if Cranium chooses to own them.

Hearth-local:

- scroll position;
- composer expanded/collapsed state;
- selected audio route;
- current local playout/mute preference;
- transient optimistic drafts;
- visual grouping choices;
- typography/style/render polish.

Audio deserves special care. Separate:

- whether Cranium should produce audio for a turn (`reply disposition`, server command/turn attribute);
- whether Hearth should currently play audio (`playout/mute`, client-local preference/state).

## Event envelope considerations

A canonical event should probably include at least:

```json
{
  "event_id": "evt_...",
  "scope": "room",
  "room_id": "hearth",
  "seq": 1234,
  "type": "message.part.appended",
  "occurred_at": "...",
  "producer": "cranium",
  "correlation_id": "cmd_...",
  "payload": {}
}
```

Open questions for the spec:

- Are sequence numbers per-room, global, or both?
- Is event ordering total per room only, or globally total?
- What is the replay horizon?
- How are duplicate events/idempotent command retries handled?
- Do projections expose `as_of_event_id`, numeric seq, or opaque cursor?
- How do schema versions appear in envelope/payload?
- How are legacy/bridge-originated events identified?

## Failover notes

The room sync model should be compatible with a future Cranium failover instance, but should not assume active-active multiwriter semantics.

Recommended initial stance:

- single active writer / warm standby;
- durable DB/event store replicated;
- standby can take over writer lease and resume;
- commands are idempotent by `client_command_id`;
- clients resume from snapshot/event cursors after reconnect.

Append-only events make failover cleaner, but they are not automatically CRDTs. CRDT-like behavior would require explicit merge/order/conflict policy. Avoid active-active unless a real policy layer exists.

## Relationship to Headjack / Matrix / legacy firehose

Headjack is KTLO legacy infrastructure and should die once Matrix is abandoned. The existing firehose should be treated as legacy, not as the foundation to preserve forever.

The new room sync API should be first-party Cranium/Hearth-native. If needed during migration, legacy Matrix/Headjack-originated activity can be normalized into the new event model, but that should be a compatibility bridge rather than the core architecture.

In other words:

```text
legacy Matrix world:
  Matrix <-> Headjack <-> current Cranium-ish paths

new Hearth world:
  Hearth <-> Cranium Sync API <-> Cranium room/event/projection core
```

## Likely API surface to design

This is a candidate set, not a mandate:

### Room list / global snapshot

```http
GET /v1/rooms
GET /v1/rooms/snapshot
GET /v1/events?scope=rooms&since=...
```

For room summaries, latest activity, unread/read markers, active turn indicators.

### Active room snapshot

```http
GET /v1/rooms/:room_id/snapshot
```

For recent transcript, room state, active turn, context state, and cursor.

### Transcript scrollback

```http
GET /v1/rooms/:room_id/transcript?before=msg_...&limit=80
GET /v1/rooms/:room_id/transcript?after=msg_...&limit=80
```

For durable scrollback from materialized transcript projection. Should return renderable message parts and an `as_of` cursor/version.

### Active room event stream/replay

```http
GET /v1/rooms/:room_id/events?since=...
```

For detailed room events. Replay if possible, otherwise explicit refresh requirement.

### Commands

```http
POST /v1/rooms/:room_id/messages
POST /v1/rooms/:room_id/audio-takes
POST /v1/rooms/:room_id/turns/:turn_id/cancel
POST /v1/rooms/:room_id/read-marker
```

Each command should accept/return a `client_command_id` or equivalent idempotency key/correlation id.

## Success criteria for Hearth

When this work is done, Hearth should be able to:

1. open a room from cold start and render recent transcript/state with no race;
2. reconnect after app suspend and catch up or refresh explicitly;
3. render historical and live assistant turns using the same message/part model;
4. render tool calls/results as structured UI elements;
5. show context saturation from canonical state, not incidental fields;
6. show room list/latest/unread/activity without detailed subscriptions to all rooms;
7. submit text/audio commands without treating command responses as render truth;
8. survive duplicate command retries without duplicate canonical messages/turns;
9. reduce or eliminate Hearth's bespoke reconciliation between history, SSE events, metadata fetches, and manifest polling.

## Suggested next step

Write a Cranium spec/Allium or design doc that nails down:

- event envelope;
- cursor semantics;
- snapshot consistency contract;
- transcript message/part projection shape;
- detailed room event taxonomy for v0;
- global room summary model for v0;
- command acknowledgement/idempotency model;
- legacy firehose/Headjack migration stance;
- explicit deferrals to avoid accidentally building Matrix II.
