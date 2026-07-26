# DONE — muse exec kill on cancel/timeout (branch `muse-kill`)

Branch only. No deploy, no service touch, no migrations, no config changes
to the running system. Branched from main @ 9017b01 (includes the fresh
`@suppressed_tools` commit).

## What changed

### The bug, restated

`Cranium.Muse.exec/4` ran through `System.cmd/3` — synchronous, no
deadline, no kill path. A hung muse exec blocked the executing process
forever. On the sync tool path that process is the Agent GenServer itself,
so a `:cancel` cast sat unseen in the mailbox and the room was wedged
until a service restart — and the muse process tree stayed running either
way.

### `lib/cranium/muse/exec.ex` (new) — `Cranium.Muse.Exec`

Port-based runner replacing `System.cmd` for exec-time invocations:

- **Deadline** — every local exec gets `:timeout_ms`; on expiry the tree
  is killed and `{:error, {:timeout, ms}}` is returned.
- **Group kill** — SIGTERM → `:kill_grace_ms` (default 500ms) → SIGKILL,
  delivered to the process *group* via `kill -s SIG -- -PGID`, so
  children-of-children die too.
- **Caller lifetime coupling** — the runner monitors its caller; if the
  caller dies mid-exec, the runner kills the tree before exiting. This is
  what makes the async-task cancel path work with zero Agent wiring.
- **Cancellable handle** — `start/2` returns a handle whose result
  arrives as a `{:muse_exec_result, ref, raw}` message, so a caller can
  selectively receive either the result or its own cancel signal, then
  `kill/2` the exec instead of awaiting it.
- `start_fun/1` runs the remote HTTP transport under the same
  handle/message contract (kill there = brutal process kill, see remote
  notes). It propagates `$callers` like `Task` does, so process-owned
  test stubs (Req.Test plugs) keep working.

**A deliberate deviation from the brief**: the brief said "spawn via a
port with `setsid`". Verified empirically (and relied on by the tests):
the erts port machinery *already* calls `setsid()` for port programs —
the spawned binary is its own session/process-group leader, and
`Port.info(port, :os_pid)` is the PGID. Wrapping in util-linux `setsid`
would actually *break* group tracking: since the child is already a group
leader, `setsid` forks, and the real group id would no longer be the
port's os_pid. So the port spawns muse directly and negative-pid kill
does the rest. This is documented in the module doc.

### `lib/cranium/muse.ex`

- `exec_start/4`, `exec_await/1`, `exec_kill/2` — the non-blocking
  handle API. `exec/4` keeps its exact blocking shape (`exec_start` +
  `exec_await`) for existing callers.
- Local execs run under `Cranium.Muse.Exec` with
  `:muse_exec_timeout_ms` (default **660_000** — muse's own bash timeout
  is 600_000, so muse's in-band timeout fires first in the normal case
  and ours is the backstop) and `:muse_exec_kill_grace_ms` (default 500).
- Result mapping keeps the existing envelope conventions
  (`unwrap_exec_output`, `exec_error`); killed execs surface as
  `"muse exec killed: cancelled"` / `"muse exec killed: timeout after Nms"`,
  which land in the tool_result via the agent's existing
  `{"error": ...}` wrapper. Never crashes the agent.
- Boot-time `--tools` / `--tools-prompt` loading still uses `System.cmd`
  (fast, boot-only, degraded-mode semantics unchanged).

### `lib/cranium/inference/agent.ex`

- **Sync tool path** (`execute_single_tool`, the path that previously
  wedged the GenServer): muse execs go through `muse_exec_cancellable/4`,
  which awaits the started exec in a receive that also matches
  `{:"$gen_cast", :cancel}`. On cancel: kill the exec (bounded by
  2×grace), then **re-queue the cast** so the main receive loop still
  runs the normal cancelled-turn path — partial output, interrupted
  context, and completed tool rounds are preserved exactly as before.
  Later muse execs in the same batch see the queued cancel via
  `cancel_pending?/0` and short-circuit without spawning a doomed OS
  process. A runner-crash `DOWN` is also matched (belt and braces — an
  unmatched DOWN would have re-created the hang we're fixing).
- **Async tool path**: no change needed, by design. `cancel_async_tasks`
  already kills the task process (`async_cancel_grace_ms` /
  `async_kill_grace_ms` house pattern); the runner's caller-monitor
  notices and reaps the muse process group.
- New `handle_info` clause ignores stray late `{:muse_exec_result, ...}`
  messages, matching the existing late-LLM-message clauses.

## Verification

Baseline before any changes: `MIX_ENV=test mix test` → **921 tests,
0 failures** (via `nix develop` — the repo pins Elixir 1.19.5/OTP 28).

After: **937 tests, 0 failures** (16 new), `mix format` clean,
`MIX_ENV=test mix compile --warnings-as-errors` clean. Nothing was run
against the live service; all kill tests use fake `muse` scripts on a
prepended PATH and `/bin/sh` stand-ins.

Suite noise triage (to keep the "no new warnings" claim honest): the
full run prints pre-existing warnings — `Tool` behaviour `schema/0`
warnings in `tool_executor_test.exs` fixtures, and
`Store operation failed: cannot find ownership process` noise from the
`humanize_ago` tests. Both were confirmed to come from files this work
didn't touch (the new test files emit neither), and the counts are
unchanged. One incidental commit (kept separate so the functional diff
stays clean): `mix format` under the flake-pinned Elixir 1.19.5
rewraps two files committed unformatted on main
(`tiamat.ex`, `http_test.exs`), plus a `.gitignore` entry for ExUnit's
`:tmp_dir` scratch directory used by the new tests.

New tests:

- `test/cranium/muse/exec_test.exs` (12) — runner unit tests: normal
  exit + output/status capture, stderr interleave, missing executable,
  cd/env application, **timeout-kill**, **explicit kill**,
  **SIGTERM-immune child escalated to SIGKILL**, **caller-death kill**,
  kill-vs-completion race returns the real result, and the fun-runner
  contract (value passthrough, exception containment, abandon-kill).
  Every kill test asserts **whole-group death including a
  child-of-a-child** (`sh -c 'sleep 300' &` grandchild) via a pgid sweep
  of the process table; the group leader pid is captured from `$$`.
- `test/cranium/muse_exec_kill_test.exs` (2) — Muse-level: a hung fake
  muse is killed at the configured deadline with exactly
  `"muse exec killed: timeout after 400ms"`, and `exec_kill` mid-flight
  yields `"muse exec killed: cancelled"`; both assert group death.
- `test/cranium/inference/agent_muse_cancel_test.exs` (2) — end-to-end
  through the Agent with a mocked LLM issuing tool calls against a
  hanging fake muse: cancel mid **sync** exec returns
  `{:error, :cancelled, partial}` promptly (< 5s asserted; actual ~½s),
  kills the group, and the kill message is present in the turn's
  persisted tool_result; cancel mid **async** (`cranium_async_mode:
  single_pass`) exec kills the task's process group promptly.

## Remote path (`exec_remote` / Muse.HTTP) — done vs. deferred

Done client-side, per brief scope:

- The HTTP call now runs in a killable process under the same handle
  contract, so agent cancel abandons it immediately instead of awaiting.
  The process is unlinked before the kill so nothing cascades into the
  agent.
- Deadline was already respected and still is: `Req` `receive_timeout` =
  the endpoint's `timeout_ms` (default 600_000) plus a 5s connect
  timeout, and the request body carries `timeout_ms` to serve.

What remote-side cleanup would need (deliberately not built — muse serve
concerns):

1. **Disconnect-triggered kill**: when the client abandons the request
   (cancel kills the client process → TCP conn closed/reset), serve's
   handler should treat request-context cancellation as "kill the exec
   subprocess group now". Without it, a cancelled remote exec keeps
   running on the remote host until its own timeout.
2. **Server-side group kill semantics**: serve already receives
   `timeout_ms`; it needs the same setsid/process-group + TERM→KILL
   escalation on its side so *its* timeout/disconnect kill reaps bash
   grandchildren, not just the direct child.
3. Optionally, an explicit kill endpoint (e.g. `POST /exec/<id>/kill`)
   if cancels need to survive scenarios where the socket teardown isn't
   observed promptly (proxies, keep-alive reuse).

## Effort accounting (for the harness-comparison corpus)

- **Wall time**: ~25 minutes end-to-end (branch created 05:25 UTC,
  final commit ~05:47 UTC, Sun 2026-07-26; the Sat-night dispatch
  executed early Sun UTC). Roughly: ~8 min reading (brief, muse.ex,
  agent.ex, http.ex, tests, configs) + empirical verification of the
  setsid/PGID/group-kill mechanics before writing code, ~7 min
  implementation, ~8 min tests, and full-suite runs overlapped with
  writing in the background (3 full runs + a `--trace` run for warning
  triage).
- **Token usage** (approximate; exact counters not visible from inside
  the session): context grew to roughly 80–90k tokens; cumulative input
  across turns on the order of 1–1.5M with prompt caching doing most of
  the work; output on the order of 25–30k tokens. One notable saver:
  testing the "are port children group leaders?" question empirically
  (two small `elixir -e` probes) before committing to a design avoided
  a likely rewrite of the kill mechanics.
- **Retries/dead ends**: one — the first full-suite attempt used system
  Elixir 1.18 and failed the project's `~> 1.19` requirement before
  switching to `nix develop`. One test-only fix: the remote transport's
  spawned process broke Req.Test stub ownership until `$callers`
  propagation was added (a real fix worth having anyway).

Merge + restart timing stays with Kevin.
