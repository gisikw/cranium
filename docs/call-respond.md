# Call / Respond — Inter-Agent Communication Primitives

> Usage and semantics reference for the `call` and `respond` tools
> (crn-7762). Behavioral spec: `specs/call-respond.allium`.

## Overview

`call` sends a message from one room's agent to another room's agent.
`respond` is receiver-side subset selection: the receiving turn runs
normally — tool calls, scratch work, everything — and `respond` marks
which part is the actual payload for the caller. **Only the respond
payload crosses back; the caller never receives the receiver's full
turn output.**

Every call gets an auto-generated `correlation_id`, stamped by Cranium
(never caller-supplied), returned in every result and threaded through
delivery and responses.

## Deprecation: the `--room` workaround

The muse `--room` dispatch pattern — where a caller received the entire
receiving agent's turn output as its tool result — is **deprecated in
favor of `call`**. It suffered duplicate token spend, offered no
receiver discretion, and supported only blocking dispatch. It remains
functional for now; removal is a separate later decision.

## The `call` tool

| Parameter | Required | Notes |
|-----------|----------|-------|
| `room` | yes | Target room. Must already exist — a typo'd room name errors instead of silently creating an empty room. |
| `message` | yes | What the receiving agent sees. |
| `disposition` | yes | `wait`, `notify`, or `mute`. |
| `timeout_ms` | no | `wait` only. Default 600000 (10 min), clamped 1s..30min. |

### Dispositions

- **`wait`** — blocks until the receiver's turn produces a `respond`
  (result: `responded` + payload), the receiver's turn ends without one
  (result: `no_reply_designated` — never a transcript fallback), or the
  timeout fires (result: `timed_out`; the call degrades to notify
  semantics, so an eventual response still arrives as pre-turn
  injection).
- **`notify`** — returns `sent` + correlation id immediately. When the
  receiver responds, the payload is injected as pre-turn context on the
  caller's next available turn, tagged with the correlation id.
  Delivery is passive: it rides the caller's next turn rather than
  waking the room.
- **`mute`** — fire and forget. Returns `sent` + correlation id; any
  respond is recorded but never delivered. Use when you cannot afford a
  reply (e.g. near context exhaustion).

### Saturation guard

A call against a room whose context saturation is at or above the
threshold (`config :cranium, :call_saturation_threshold`, default 0.9)
returns `receiver_saturated` (with the observed saturation) instead of
piling on. Nothing is delivered; the caller decides what to do.

### Queueing

A call against a room that is busy mid-turn queues for the next turn
boundary via the existing per-room message queue. Delivery guarantee is
"it landed in the room queue," nothing more — **no durability, no
retry**. If a dispatch needs those, that's a workflow poking a room,
not this system's job.

## The `respond` tool

| Parameter | Required | Notes |
|-----------|----------|-------|
| `correlation_id` | yes | Which incoming call this answers. |
| `payload` | yes | What crosses the wire. Nothing else does. |

Multiple responds with the same correlation id append and deliver in
order (a `wait` caller unblocks on the first; the rest arrive as
pre-turn injections). A respond with an unknown or foreign correlation
id (one addressed to a different room) errors.

## Receiving side

An incoming call arrives as a normal room message, wrapped in an
`<incoming-call>` block carrying the originating room, correlation id,
and disposition, plus a reminder that `respond` is available for it.
Rooms are symmetric peers — the receiver can itself `call` other rooms,
including calling back the originator. Long async exchanges compose as
notify-call one way, notify-call back, correlation ids threading the
exchange.

Delivered calls carry `origin: "call:<caller_room>"` (visible in
`message.created` events) and thread `depth = caller_depth + 1` through
the PassHeader, so the existing `MUSE_ROOM_DEPTH` recursion guard sees
call-chains exactly as it saw `--room` chains.

## Deadlock backstop

**The backstop is the timeout, not cycle detection.** A `wait` chain
A → B → A will jam until the caller's timeout fires (at which point the
call degrades to notify semantics and everything unwinds). This is
accepted for v1 — prefer `notify` for anything that might re-enter the
calling room.

## Boundaries

- No durability, no retry — correlation state is in-memory and
  expendable (swept 24h after creation).
- No caller-side truncation heuristics — receiver discretion via
  `respond` is the only payload-selection mechanism.
- Self-calls are rejected.
