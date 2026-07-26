# muse-kill live failure — Sun Jul 26 ~1:30 AM Central

Branch merged to main at ~1am (fast-forward to b4c77d7 + flake fix 19ef4e9),
CI deployed, cranium restarted. Reverted via force-push (main back to 9017b01)
after the live session lost all tool access.

## Observed (from inside the live #kestrel session)

- Post-restart, the FIRST muse exec succeeded normally (`echo alive; ls`).
- Every subsequent tool call — bash, read, everything — failed with exactly:
  `"muse exec runner exited: :normal"`
- Consistent across retries and across tool types. One success then permanent
  failure suggests state poisoning or a message-delivery race, not total
  breakage.

## Error shape analysis

The message means an awaiter observed the runner's DOWN (`:normal` exit)
without ever matching its `{:muse_exec_result, ref, raw}` message. The runner
completed fine — the RESULT never reached the process doing the await.

Suspects, in rough order:

1. **Result sent to the wrong pid on a live path.** If `exec_start` and
   `exec_await` run in different processes anywhere in production (tool
   executor / async task topology differs from the test harness), the result
   message lands in the starting process's mailbox while the awaiting process
   only ever sees the monitor DOWN.
2. **The stray-result `handle_info` clause eats it.** The Agent got a new
   clause ignoring late `{:muse_exec_result, ...}` infos. If the result is
   delivered to the Agent process while the await happens elsewhere (or after
   a selective-receive window closes), the clause silently discards it.
3. **DOWN-vs-result ordering** in the belt-and-braces receive — if DOWN can be
   processed while the result is already queued behind it, the await returns
   the runner-exited error despite the result being present. (Same-sender
   ordering should prevent this if monitor and send originate from the same
   process — verify the monitor is on the runner and the runner sends the
   result itself before exiting.)

Also worth checking: whether the ONE successful exec matters — e.g. some
per-agent or pooled state (a lingering monitor ref, a subscription, a
process-dictionary key) left behind by the first exec that poisons the next.

## Repro honesty

937 tests green did NOT catch this; the e2e agent tests use a mocked LLM and
a fake muse but apparently not the production process topology for the sync
tool path under a REAL streaming turn. Whatever fix lands must add a test
that fails on b4c77d7 for this exact shape.

## Status

- main: reverted to 9017b01, redeployed, live service healthy.
- muse-kill branch: b4c77d7 + cherry-picked 2a8143d (flake inotify-tools +
  procps — CI-pure test deps, keep regardless).
- Re-merge gate hardened: green suite is NOT sufficient; needs a live
  acceptance pass (real room, real streaming turn, multiple sequential tool
  calls, a cancel) before it touches main again.
