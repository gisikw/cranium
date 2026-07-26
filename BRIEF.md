# burn-cranium — muse exec kill on cancel/timeout (branch only, NO deploy)

Dispatched Sat Jul 25 night. Host: ratched (local). Project ~/Projects/cranium.

## HARD BOUNDARIES — read twice

- Branch `muse-kill` ONLY. NEVER commit to main. NEVER push main.
  Push the branch to forgejo as backup — that's fine.
- NEVER restart, redeploy, or touch the running cranium service. It is
  serving LIVE conversations right now (including the one that dispatched
  you). Merge + restart is Kevin's daylight call, deliberately timed.
- No migrations, no config changes to the running system.
- NOTE: lib/cranium/muse.ex has a fresh commit on main (@suppressed_tools,
  9017b01) — branch from current main, don't fight it.

## The bug

`Cranium.Muse.exec/4` → `exec_local/1` → `run/2` → `System.cmd(muse, ...)`.
`System.cmd` is synchronous and unbounded: no timeout, no kill path. When an
agent turn is cancelled, `Agent`'s cancel path kills the LLM streaming process
and reaps async tasks — but a muse exec already in flight just keeps running,
and because the executing process is blocked in `System.cmd`, the turn is held
open indefinitely. A muse bash tool call that hangs (network, interactive
prompt, runaway child) wedges the room until someone SSHes in and restarts
cranium. This has happened repeatedly; it is the problem to solve.

## Required behavior

1. **Deadline:** every local muse exec gets a timeout (config:
   `:muse_exec_timeout_ms`, sensible default — muse's own bash default is
   600_000; the outer bound should exceed it slightly, e.g. 660_000, so muse's
   own timeout fires first in the normal case and ours is the backstop).
2. **Kill semantics on timeout or cancel:** the muse process AND its entire
   process group/tree must die (muse spawns children — bash spawns more).
   Spawn via a port with `setsid` (own process group), kill with
   SIGTERM → short grace → SIGKILL to the group (`kill -- -PGID`).
3. **Cancel wiring:** when the Agent is cancelled (`:cancel` cast paths in
   lib/cranium/inference/agent.ex — both the sync tool-execution wait and the
   async task machinery in the same file + cancel_async_tasks), any in-flight
   muse exec must be killed promptly, not awaited. Study how async tool tasks
   are already cancelled (async_kill_grace_ms pattern) and match the house
   style.
4. **Result shape:** a killed exec returns an error tuple that lands in the
   tool_result as a clear message ("muse exec killed: cancelled" /
   "muse exec killed: timeout after Nms") — same envelope conventions as
   existing exec_error output. Never crash the agent; never lose the turn's
   partial output (cancelled-turn persistence semantics must be preserved).
5. **Remote path (`exec_remote` / Muse.HTTP):** out of scope for kill-the-
   process (the process is on another host), but the HTTP call should respect
   the same deadline and abandon cleanly on cancel. Document in DONE.md what
   remote-side cleanup would need (likely a muse serve concern) — don't build it.

## Verification

- Unit tests around the new runner: exits-normally, timeout-kill (spawn
  `sleep 300` via a fake/real muse invocation or a test binary standing in),
  cancel-kill mid-exec, process-GROUP death (child of child dies too — assert
  no orphan via ps/pgid check), result-shape assertions.
- Full existing suite stays green: `MIX_ENV=test mix test` (baseline ~921+
  tests, 0 failures expected).
- `mix format` + compile with no new warnings.
- Do NOT test against the live service.

## Deliverable

DONE.md on the branch: what changed, how verified, remote-path notes, and —
Kevin's ask — a rough accounting of your own effort (wall time, approximate
token usage if visible to you) since this task is a candidate for a future
harness-comparison eval corpus. NEEDS-KEVIN.md instead if genuinely blocked.
Merge/deploy timing stays with Kevin.
