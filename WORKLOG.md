# Worklog

Decisions and open questions, newest first. Per instructions.md: keep
this current as work proceeds.

## Gee belief injection (Dispatch B — Phase 2 static injection)

Design note: `docs/gee-belief-injection.md`. Judgment calls made
without stalling, per the dispatch:

- **Transport: colocated file read.** Cranium's overlay runs as user
  `dev` with `HOME=/home/dev` on ratched — the same host and user that
  own `~/.config/gee/`. A file read of the published artifact is
  strictly simpler than HTTP or a fort capability and loses nothing.
  The read is isolated in `Cranium.Context.BeliefBridge` if the
  topology ever changes.
- **Publisher placement.** The fort overlay manager only supports
  long-running services, not timers, so the publisher lives as a plain
  systemd timer+oneshot in ratched's host `module` block (fort-nix
  branch `gee-bridge-publisher`, needs merge + gitops deploy). The gee
  binary is dev-managed at `~/.local/bin/gee` (precedent: dwim, gloss,
  etc.); built and installed during this dispatch.
- **Delta detection compares the full injected ID set** (pinned +
  surfaced), not just the surfaced band. A pinned belief appearing
  mid-snapshot is also worth reinjection, and one comparison is
  simpler than two. Confidence/status drift on an unchanged set does
  not retrigger (spec: membership change only).
- **Mid-session first appearance injects.** If `last_belief_ids` is
  nil mid-epoch (bridge came up after session start, or pre-migration
  epoch), the block injects as a delta — that's "the band entering
  from nothing," and it means beliefs reach long-lived rooms without
  waiting for an epoch clear.
- **Ephemeral passes skip the source.** The injection wouldn't
  persist, but `last_belief_ids` would claim it's in context —
  same reasoning as call-response injections skipping ephemeral.
- **Stale/missing bridge warns at session start, debug mid-session.**
  A per-turn warning for a down publisher would spam every turn of
  every room; session start is the moment the absence matters most.
  Acceptance criterion 5 reads as "a warning is logged," not "every
  turn warns."
- **Token counting rail created, not found.** The primer says
  injection metadata already counts tokens per source; in reality no
  per-source injection counter existed. Added a generic
  `context.injection.recorded` room event (source/tokens/kind/count)
  plus the JSONL manifest. Other sources (landscape, steering) can
  ride the same event later.
- **Budget enforcement is exact against the formatted block** (shrink
  until the ~4-chars/token estimate fits), not a per-line
  approximation — the ceiling is a hard number in the signed design,
  so the enforced quantity is the same one that gets logged.

### Parked questions

- Should the surfaced band refresh also have a turn-cadence floor
  (e.g. don't reinject more than once per N turns even on delta)?
  15-min snapshots make thrash unlikely; revisit if the manifest shows
  churn.
- `gee eval` also touches the *item* store's access tracking when the
  publisher runs — pre-existing gee behavior, out of scope here, but
  worth a look when Phase 3 dynamics land (does a 15-min eval cadence
  distort item curves?).
- Landscape/time-gap sources could report into the same
  `context.injection.recorded` event for a complete per-source budget
  dashboard (§5.3.1). Deferred — only gee-beliefs was in scope.

## crn-7762 — call/respond inter-agent communication primitives

### Architecture

- New actor `Cranium.Calls` (GenServer, app-supervised, last in the
  supervision tree so its crash restarts nothing downstream). Owns all
  correlation state in memory — no durability, per the brief's
  boundaries. Two private-to-the-actor modules:
  - `Cranium.Calls.Logic` — pure decision functions (validation,
    routing of responds, message/injection formatting). Unit-tested.
  - `Cranium.Calls.Delivery` — plumbing that submits a pass to the
    target room (same mechanics as ContinuationDispatcher: pass_header
    + text_input broadcast). Swappable via
    `config :cranium, :call_delivery` for tests.
- `call` / `respond` are first-class builtin tools
  (`Cranium.Inference.Agent.Tools.{Call,Respond}`), routed explicitly
  in ToolRouter ahead of muse (so a muse tool can never shadow them)
  and advertised in `tool_definitions/1`. They ride the existing
  `{:execute, module, input}` path, which also makes them
  `cranium_async_mode`-capable for free (a `wait` call can be
  backgrounded with `single_pass` like any other async-eligible tool).

### Decisions

- **Receiver turn correlation** is by `stream_id`: Delivery generates
  the pass's stream_id, `Cranium.Calls` subscribes to global events and
  watches for `{:pass_complete, _, stream_id, _}`. Turn end without a
  respond → `no_reply_designated` (any pass_complete reason — complete,
  cancelled, error — counts as "turn ended").
- **`wait` unblocks on the first respond.** Later responds with the
  same correlation id (same turn or later turns) are delivered in order
  via the pre-turn injection path — same machinery as `notify` and as
  timeout degradation. This satisfies "append, deliver in order"
  without holding the caller blocked after it has its answer.
- **Late responds are allowed.** Correlation records outlive the
  receiving turn (swept after 24h). A respond after
  `no_reply_designated`/`timed_out` still reaches the caller as
  pre-turn injection; a respond to a `mute` call is recorded and never
  delivered. Rationale: the correlation id lives in the receiver's
  transcript, and the brief's "or contains" wording plus the
  async-composition story argue for permissiveness.
- **Target room must already exist** (`Store.get_injection_context/1`
  returns an active epoch). Calling an unknown room errors rather than
  implicitly creating one — a typo'd room name should not spawn a
  fresh empty room and swallow the message.
- **Self-calls are rejected** in v1. `wait` to self would always jam
  until timeout (own room is mid-turn by definition); allowing
  notify-to-self as a "next-turn reminder" is a possible later
  extension, not this brief.
- **Saturation gate**: `config :cranium, :call_saturation_threshold`
  (default 0.9), checked against the target's epoch saturation at call
  time. Saturated → `receiver_saturated` with correlation id returned
  but nothing delivered and no record kept (a respond to that id errors
  as unknown, which is accurate — the receiver never saw it).
- **Timeout**: default 600_000 ms, clamped to 1s..30min. The tool
  module's static `timeout/0` (30min + slack) is only the
  ToolExecutor backstop; the real timer lives in `Cranium.Calls` and
  degrades the call to notify semantics.
- **Depth threading**: a delivered call pass carries
  `depth = caller_depth + 1` in its PassHeader, so the existing
  MUSE_ROOM_DEPTH recursion guard sees call-chains exactly as it saw
  `--room` chains. No new cap enforced by the call system itself (the
  brief's backstop is the timeout, not cycle detection).
- **Injection delivery point**: TurnAssembler drains pending call
  responses from `Cranium.Calls` during context assembly and merges
  them with plugin injections at priority 25 (after landscape 20,
  before saturation 30). Skipped for orientation and ephemeral passes
  (orientation is private journaling; ephemeral turns don't persist,
  so consuming an injection there would lose it). The drain is
  try/caught so a dead Calls process can't take conversations down.
- **Injection cap**: pending injections per room are capped at 50
  (oldest dropped, logged) so an abandoned room can't accumulate
  unbounded responses.
- **Errors surface as tool-result JSON** (`{"error": ...}`) rather
  than `{:error, ...}` tuples, matching how bash/subagent report
  failures to the model in-band.

### Incidental fixes (pre-existing, surfaced by recompile under --warnings-as-errors)

- `Cranium.Inference.Agent` used an undefined `@registry` attribute in
  the turn-state snapshot-recovery helpers (crn-a0f5) — it evaluated to
  nil, every Registry call raised ArgumentError, and the rescue clauses
  silently no-op'd. Defined it as `Cranium.Inference.ConversationRegistry`
  (matching what Snapshot.detect_active_turn reads), which makes
  mid-turn snapshot recovery actually register state. Latent bug fix,
  not just a warning fix.
- Removed dead `error_html/1` in `Cranium.Transport.Diagnostics`
  (unused private function warning).

### Test coverage notes

- Pure logic (`Cranium.Calls.Logic`) unit-tested; the exchange
  (`Cranium.Calls`) integration-tested against the app-started instance
  with a stubbed delivery module (`Cranium.Test.CallDeliveryStub` via
  `config :cranium, :call_delivery`) so tests observe deliveries
  without spawning live conversations/inference. Receiver turn
  boundaries are driven by sending `{:pass_complete, ...}` directly to
  the exchange (same pattern as PassReactor tests).
- The TurnAssembler → TurnInjector injection merge is not covered by a
  full turn-assembly test (no existing harness for TurnAssembler); the
  drain path and priority wrapping are exercised via
  `drain_injections/1` tests and the try/catch degrade is trivial.

### Open questions

- Should `respond` be advertised only when the room has an open
  incoming call? Chose always-advertise for v1 to keep tool
  definitions stable for prompt caching; the tool errors cleanly on
  unknown/foreign correlation ids.
- `receiver_saturated` currently reflects saturation at call time
  only; a queued call can still land on a room that saturates
  mid-queue. Revisit if it bites.
- Room-event observability (e.g. `call.placed` / `call.responded`
  durable events, threading the existing room-event `correlation_id`
  column) deliberately deferred — the delivered pass already produces
  normal `message.created` events with origin `call:<caller>`.
- `no_reply_designated` does not distinguish receiver turn outcome
  (completed vs errored vs cancelled). Could carry the pass_complete
  reason if callers need it.
