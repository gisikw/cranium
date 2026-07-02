# Agent Instructions — Cranium

Standing briefs for dispatched agents. Read the section you were pointed
at, follow repo conventions (specs/, INVARIANTS.md, `just check`), and
keep the worklog discipline: decisions and open questions go in
WORKLOG.md as you go.

**HARD CONSTRAINT FOR ALL BRIEFS IN THIS FILE: commit locally, do NOT
push.** Cranium is a live service deployed via GitOps; pushing restarts
it and can kill in-progress work. Kevin reviews and pushes manually.

---

# Call / Respond — Inter-Agent Communication Primitives (crn-7762)

## Why

Agents currently coordinate across rooms via a `--room` dispatch
workaround whose tool result is the *entire* receiving agent's turn
output — duplicate token spend, no receiver discretion, and blocking is
the only mode. This is load-bearing today (e.g. "go ask the fort-nix
agent to investigate X but tell it not to execute"). Replace it with
first-class primitives.

These live in Cranium (not Muse) because call semantics are statements
about rooms, epochs, and saturation — state only Cranium has. Reuse the
existing async-tool machinery (`cranium_async_mode` ack/inject pattern)
wherever it fits; this is an extension of that plumbing, not a parallel
system.

## The two tools

### `call`

One tool, disposition decides the shape. Sends a message to another
room's agent.

Parameters:

- `room` (required) — target room.
- `message` (required) — what the receiving agent sees.
- `disposition` (required enum):
  - `wait` — block until the receiver's turn produces a `respond` (or
    the turn ends). Tool result = the responded payload + correlation
    id. If the receiver's turn ends **without** calling `respond`, the
    caller gets an explicit `no_reply_designated` status — NEVER a
    full-transcript fallback (that reintroduces the double-spend).
  - `notify` — return immediately with the correlation id. When the
    receiver eventually responds, inject the payload as pre-turn
    context on the caller's next available turn, tagged with the
    correlation id.
  - `mute` — fire and forget. Return the correlation id; any `respond`
    from the receiver is recorded but never delivered to the caller.
    (Use case: caller is near context exhaustion and cannot afford a
    reply.)
- `timeout_ms` (optional, `wait` only) — sane default (suggest 10 min,
  matching tool timeout norms). On timeout the call degrades to
  `notify` semantics: caller gets correlation id + `timed_out` status;
  the eventual response, if any, arrives as pre-turn injection.

Returns: always includes an auto-generated `correlation_id`. This is
not optional and not caller-supplied — Cranium stamps it.

### `respond`

Available to an agent whose current turn was initiated by (or contains)
an incoming call. Receiver-side subset selection: the receiver's turn
runs normally — tool calls, scratch work, everything — and `respond`
marks which part is the actual payload for the caller. Only the
receiver knows answer vs. workings.

Parameters:

- `correlation_id` (required) — which incoming call this answers.
- `payload` (required) — what crosses the wire. Nothing else does.

Multiple `respond` calls with the same correlation id: append, deliver
in order. `respond` with an unknown/foreign correlation id: error.

## Delivery semantics on the receiving side

An incoming call arrives as a normal room event/message (like a message
from a colleague), clearly attributed: originating room, correlation
id, and a note that `respond` is available for it. Symmetric peers —
the receiver can itself `call` other rooms, including calling back the
originator (this is how long async exchanges compose: notify-call one
way, notify-call back, correlation ids thread it).

## Saturation awareness

A `wait` call against a room that is busy mid-turn queues for the next
turn boundary (existing message queueing). A call against a room whose
context saturation is critically high (use the existing 0..1 saturation
fraction from room sync; pick a threshold, suggest ≥0.9) should return
a `receiver_saturated` status rather than silently piling on. Caller
decides what to do with that.

## Boundaries (do not cross)

- **No durability, no retry.** Delivery guarantee is "it landed in the
  room queue," nothing more. If a dispatch needs durability or retry,
  that's a Kobold workflow poking a room — not this system's job.
- **No caller-side truncation heuristics.** Receiver discretion via
  `respond` is the only payload-selection mechanism.
- **Deadlock backstop is the timeout**, not cycle detection. A `wait`
  chain A→B→A will jam until timeout; that's acceptable for v1. Note it
  in docs.

## Acceptance

- `wait` call round-trips a respond payload; `no_reply_designated` when
  receiver never responds; `timed_out` degrades to notify.
- `notify` call returns immediately; respond payload arrives as
  pre-turn injection with correlation id on the caller's next turn.
- `mute` call: respond recorded, never delivered.
- Saturated receiver returns `receiver_saturated` on new calls.
- Multiple responds append in order; foreign correlation id errors.
- Old `--room` workaround path documented as deprecated in favor of
  `call` (removal is a later decision, not this brief).
- Specs amended per repo convention; `just check` green.
- **Committed locally. NOT pushed.**
