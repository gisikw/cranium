# Brief: cranium exec-endpoint — remote muse execution (cranium repo)

## Diagnosis

Cranium runs Muse tool calls by shelling out locally:
`Cranium.Muse.exec/4` (`lib/cranium/muse.ex`) builds argv
(`--rw`/`--ro` grants + `--exec <payload>`), sets `cd: working_dir`, and runs
the `muse` binary. This pins every session's tool execution to the box
cranium runs on (ratched).

We are giving muse an HTTP daemon (`muse serve`, being built in parallel in
the muse repo) so tool execution can happen on another host (obrien, a mac
mini) while cranium stays on ratched. From the agent's perspective a session
should simply *feel like* it runs on the remote box.

**The wire contract is: the HTTP request carries exactly what the CLI
invocation would.** `muse serve` is a thin transport over the existing
CLI: request = exec payload JSON + working dir + rw/ro grant lists + env
additions (e.g. MUSE_ROOM_DEPTH); response body = exactly what `--exec`
prints on stdout (same ExecResult wrapper) plus an exit-code field;
`GET /tools` = byte-identical `muse --tools` output. Auth = static bearer
token on every request. Build cranium's client side to THAT mapping — mirror
how `exec/4` builds argv today, field for field. Do not invent additional
protocol.

## Requirements

1. **Config:** an exec-endpoint setting on the room/session profile (follow
   however per-room/profile config is currently shaped — read the profile
   plumbing first): endpoint URL + token (token via env/file indirection,
   never a literal in config). Unset = today's behavior, byte-identical.

2. **`Cranium.Muse.exec/4` routes on it:** endpoint set → HTTP POST with the
   same fields it would have put on argv; unset → existing shell-out path,
   untouched. Keep the graceful-degradation posture symmetric: unreachable
   endpoint should degrade/log the way a missing muse binary does today, not
   crash the session.

3. **Timeouts:** generous, configurable per-call ceiling (bash can run
   minutes). A timed-out call returns a tool error to the agent, same as
   local failures do.

4. **Remote working dirs:** the session working directory for a remote-exec
   room refers to the REMOTE filesystem. Audit what cranium does with
   working dirs locally (existence checks, creation, the projects-dir
   room-matching logic) and make remote-exec rooms not assume the path
   exists locally. Smallest honest change wins; document what you found.

5. **Tools stay boot-loaded locally.** Tool definitions are flat and
   identical across hosts (Kevin's ruling). Do NOT build per-endpoint tool
   caching. `load_tools!` stays as is.

## Explicitly OUT of scope (list in DONE.md as known follow-ups; do not build)

- **Subagent/delegate:** `lib/cranium/inference/agent/tools/subagent.ex`
  shells out to the `claude` binary locally and bypasses Muse entirely —
  on a remote-exec room, subagents would silently run on the wrong host
  AND on a binary we thought we'd decoupled from. Known problem, tracked
  separately. Do not fix it here; do not route it through the endpoint.
- Macros (invoked as tools but executed by cranium; needs its own design).
- Streaming exec (v1).
- Worker discovery/registration — endpoints are pinned config, not a fleet.

## Hard constraints

- Branch `burn/exec-host`. NEVER commit to main.
- The muse repo is read-only reference (`~/Projects/muse`); the serve
  implementation may not exist yet — build to the mapping above, with the
  HTTP client isolated behind a small module so any late delta in the serve
  implementation is a one-file fix.
- Local behavior with no endpoint configured must be byte-identical —
  existing tests must pass unmodified (if a test must change, justify it in
  DONE.md).
- `MIX_ENV=test mix test` green; dialyzer clean (`mix dialyzer`).
- Tests: use a stub HTTP server (Bypass or equivalent already in deps —
  check first) to cover: happy path, 401, timeout, unreachable-endpoint
  degradation, grants/env fields present in the request, response unwrap
  identical to the CLI path.

## Acceptance criteria

- Room profile with exec-endpoint set → `Muse.exec` POSTs (asserted via stub
  server); without → shells out exactly as before.
- Request fields mirror today's argv construction one-for-one (grants, cwd,
  env additions, payload).
- Response unwrapping shares the existing `unwrap_exec_output` path.
- Full suite green, dialyzer clean, main untouched.
- DONE.md: config shape chosen (and why), working-dir audit findings, wire
  mapping as implemented, out-of-scope list restated, verification record.

## Verification independent of self-report

Reviewer will run the suite, read the stub-server tests, grep that
`subagent.ex` is untouched, and later point a real room at a scratch
`muse serve` from the sibling branch for the end-to-end check.
