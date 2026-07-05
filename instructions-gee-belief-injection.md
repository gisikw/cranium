# Dispatch B — Gee belief injection into Cranium (Phase 2: static injection)

Goal: every Cranium room session starts with Exo's pinned core-self
beliefs + the surfaced band in context, at ~1% of context, with
measurement counters. This is Phase 2 of the signed Gee design.

## Read first

1. `~/Projects/hoard/primers/gee-wyrmling-merge/index.md` — §4.2
   (injection), §5.1 (budget table — BINDING numbers), §5.3 (measurement).
2. `~/Projects/gee/INVARIANTS.md` and the `--bridge` output format
   (`format.go`, `beliefeval_test.go` show the shape: top-level
   `beliefs`/`pinned` attributes + inner `<beliefs>` element).
3. Cranium's existing pre-turn injection pipeline (time-gap, landscape,
   saturation sources) — the belief block is a NEW SOURCE in that
   pipeline, same priority-slot mechanics.

## The one hard constraint: single writer

`gee eval` MUTATES the belief ledger (mechanical transitions append
status events — acceptance read o1). Therefore **Cranium never invokes
`gee` directly.** Architecture:

- A periodic systemd timer/service (host: wherever `~/.config/gee/`
  lives — the dev host; check with Exo via WORKLOG if unclear) runs
  `gee eval --bridge` and publishes the output atomically to a
  well-known path (write temp + rename). Suggested cadence: every 15
  min. This job is the ONLY eval caller.
- Cranium reads the published bridge artifact (file read if colocated,
  HTTP/fort capability if cross-host — pick the simplest thing that
  works with existing infra and document the choice).
- Stale artifact (>2h old or missing) → inject nothing + log a warning.
  Never block a turn on the bridge.

## Injection behavior (v1 = static, per phasing §7.2)

- **Session start:** inject pinned set + surfaced band as one belief
  block. Format: compact, one line per belief (id, statement,
  confidence, flags like contested/stale). Budget: hard ceiling 5% of
  working context, expected ~1.2%; if over budget, highest-activation
  wins, rest dropped (§5.1).
- **Mid-session:** refresh ONLY on delta (a belief entering/leaving the
  surfaced band between bridge snapshots), not every turn.
- No steering/interrupt path in this dispatch (that's Phase 5 — do not
  build it).

## Measurement (the part Kevin required at sign-off)

Ride existing injection-metadata rails:

- Count injected belief-block tokens per session/turn, tagged as source
  `gee-beliefs`, visible wherever other injection sources are counted.
- Log per-injection manifest (which belief IDs were in context) —
  needed later for reference-rate and holdout analysis; storage can be
  a simple append log keyed by room/epoch/turn. Design for the nightly
  accretion pass (Dispatch C) to consume it.

## Deliverables

- Cranium changes on a branch, tests passing, following repo
  conventions (check existing source modules for style).
- The eval-publisher unit (systemd timer or equivalent; if fort-nix
  config is needed, write the module + note it needs deploy).
- A short design note in `docs/` recording: artifact path/transport,
  cadence, staleness policy, budget enforcement, manifest log location.
- WORKLOG entries for judgment calls; park questions rather than stall.
- e2e demonstration: with a populated ledger (Dispatch A may still be
  running — a fixture ledger via `GEE_BELIEF_STORE`/`GEE_BELIEF_LOG`
  overrides is fine for dev), show a real room session receiving the
  belief block, and show the token count in the metadata.

## Acceptance criteria

1. Belief block appears at session start in a live room; delta-only
   refresh verified mid-session.
2. Cranium performs zero writes to the belief ledger (code inspection +
   no eval invocation anywhere in Cranium).
3. Budget enforced: block ≤5% context, measured and logged.
4. Injection manifest log exists and records belief IDs per injection.
5. Stale/missing bridge artifact degrades gracefully (no crash, no
   block, warning logged).
