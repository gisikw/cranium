# Gee belief injection (Phase 2: static injection)

Every room session starts with Exo's pinned core-self beliefs and the
surfaced band in context, with measurement counters. This implements
Phase 2 of the signed Gee design
(`hoard/primers/gee-wyrmling-merge/index.md`, §4.2/§5.1/§5.3).

## Architecture: single writer

`gee eval` mutates the belief ledger (mechanical status transitions
append events), so **cranium never invokes gee**. The split:

- **Publisher** — a systemd timer on ratched (`gee-bridge-publisher`,
  defined in fort-nix `clusters/bedlam/hosts/ratched/manifest.nix`) runs
  `gee eval --bridge` as user `dev` every 15 minutes and publishes the
  output atomically (write temp + rename) to
  `/home/dev/.local/state/gee/bridge.txt`. This unit is the **only**
  eval caller. The gee binary is dev-managed at `~/.local/bin/gee`.
- **Reader** — cranium runs on the same host as the same user
  (overlay.nix: `user = "dev"`, `HOME=/home/dev`), so the transport is
  a plain file read. No HTTP, no fort capability — colocated file read
  is the simplest thing that works. If cranium ever moves hosts, the
  artifact needs to move to a fort capability or HTTP fetch; the read
  is isolated in `Cranium.Context.BeliefBridge`.

## Artifact and transport

| Item | Value |
|---|---|
| Artifact path | `/home/dev/.local/state/gee/bridge.txt` (`GEE_BRIDGE_PATH`) |
| Publisher cadence | every 15 min (`OnUnitActiveSec`), 2 min after boot |
| Atomicity | write `bridge.txt.tmp.$$` + rename |
| Staleness policy | mtime older than 2h → treat as absent, inject nothing, log (warning at session start, debug mid-session). A missing/unreadable/empty artifact degrades the same way. Turns are never blocked on the bridge. |

The artifact is the full `gee eval --bridge` output; cranium extracts
only the inner `<beliefs pinned="N" surfaced="M">` element. Section
membership comes from the `pinned` count attribute (the `---` separator
is omitted when either section is empty). Lines are used verbatim —
gee owns the belief line format (id, statement, confidence, status
flags).

## Injection behavior (v1 = static, phasing §7.2)

- **Session start** (fresh epoch, including the orientation pass, which
  persists and anchors the session): pinned set + surfaced band as one
  `<system-reminder>` block, priority 15 in the turn-injection order
  (after time, before landscape).
- **Mid-session**: reinject only when the belief-ID set changes between
  bridge snapshots (a belief entering/leaving the band). Confidence or
  status drift on an already-injected belief does not retrigger.
  Detection compares the current snapshot's IDs against
  `epochs.last_belief_ids` (updated on every injection).
- **Ephemeral passes**: skipped — the injection wouldn't persist while
  `last_belief_ids` would claim it's in context.
- No steering/interrupt path (Phase 5; deliberately not built).

## Budget enforcement (§5.1 — binding)

Hard ceiling **5% of the working context** (`budget_fraction: 0.05` in
`config :cranium, :gee_beliefs`; context window from the profile's
`context_window`, default 200k). Expected footprint ~1.2%. Enforcement
in `Cranium.Context.BeliefInjection`: keep a prefix of
pinned-then-surfaced (the bridge emits the band activation-descending),
shrinking until the formatted block's token estimate (~4 chars/token,
same heuristic as Harness saturation) fits. Pinned outrank the band;
highest activation wins; the drop count is recorded in the manifest.

## Measurement (§5.3)

- **Token count per injection**, tagged source `gee-beliefs`:
  - `context.injection.recorded` room event (payload: source, tokens,
    kind, count) — on the same durable room-event stream as saturation
    updates. This is a new generic rail; future sources (landscape,
    steering) can ride it.
  - `TurnAssembler: belief block injected source=gee-beliefs ...` log
    line with kind/count/tokens/dropped.
- **Injection manifest** — append-only JSONL at
  `/home/dev/.local/state/cranium/belief-manifest.jsonl`
  (`GEE_BELIEF_MANIFEST_PATH`), one record per injection:
  `{at, source, room, epoch_id, turn, kind, ids, tokens, dropped}`.
  This is the input for reference-rate and holdout analysis; the
  nightly accretion pass (Dispatch C) consumes it to distinguish
  evidence that arose with a belief in context from evidence that arose
  independently. Writes are best-effort and never block a turn.

## Module map

| Module | Role |
|---|---|
| `Cranium.Context.BeliefBridge` | read + parse the published artifact (thin I/O, pure parse) |
| `Cranium.Context.BeliefInjection` | pure decision: session-start/delta/skip, budget fit, block format |
| `Cranium.Context.BeliefManifest` | append-only injection manifest |
| `Cranium.Context.TurnInjector` | belief source at priority 15; threads metadata out |
| `Cranium.Inference.TurnAssembler` | config + epoch state in; persists `last_belief_ids`, manifest append, room event |

## Deploy notes

- fort-nix branch `gee-bridge-publisher` adds the timer to ratched's
  manifest — needs merge + gitops deploy.
- cranium migration `20260705000001_add_belief_state_to_epochs` runs on
  release start (migrate-then-start exec in overlay.nix).
- `~/.local/bin/gee` must exist on ratched (`go build -o ~/.local/bin/gee`
  in `~/Projects/gee`) — done during this dispatch.
