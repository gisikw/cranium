# DONE: cranium exec-endpoint — remote muse execution

Branch `burn/exec-host` (based on `main` @ 81afa71). Main untouched.

## What was built

`Cranium.Muse.exec/4` now routes on a per-profile `exec_endpoint`: set → HTTP
POST to a remote `muse serve` daemon; unset → the existing shell-out path,
byte-identical. Tool definitions stay boot-loaded from the local binary
(`load_tools!`/`load_tools_prompt!` untouched, per Kevin's flat-tools ruling).

Files:

- `lib/cranium/config.ex` — `exec_endpoint` profile parsing + validation
- `lib/cranium/muse.ex` — shared exec-request construction, local/remote routing
- `lib/cranium/muse/http.ex` — **new**, all HTTP protocol knowledge lives here
- `lib/cranium/context/router.ex` — `remote_working_dir/2`
- `lib/cranium/inference/turn_assembler.ex`, `harness.ex`, `agent.ex` — threading

## Config shape chosen (and why)

```yaml
profiles:
  obrien-xcode:
    backend: tiamat
    router_profile: exo
    exec_endpoint:
      url: http://obrien:7777
      token_env: MUSE_EXEC_TOKEN        # or token_file: /run/secrets/muse-token
      projects_dir: /Users/kevin/Projects
      timeout_ms: 600000                # optional; default 600_000
```

- **Why a profile field:** all existing per-room tool behavior (`tool_posture`,
  `tool_rw`, `tool_ro`, `tools_disabled`) is profile-shaped and reaches
  `Muse.exec` via profiles.yaml → `Cranium.Config.Profile` → turn assembler →
  harness context → agent opts → `tool_config`. `exec_endpoint` follows the
  identical path; rooms opt in via the existing `room_defaults` mapping.
- **Token indirection enforced:** a literal `token:` key raises at config
  load. `token_env`/`token_file` are resolved per call (rotation without
  restart); missing/empty token degrades to a tool error without attempting
  a request.
- **`projects_dir` is required and must be absolute.** It names the REMOTE
  projects root, which cannot be inferred locally, and `~` would expand
  against the local HOME (`/home/dev` on ratched vs `/Users/kevin` on
  obrien). Failing at config load beats failing on every tool call.
- **`timeout_ms` optional**, defaults to 600s (bash can run minutes). A
  timed-out call returns a tool error to the agent, same as local failures.

## Wire mapping as implemented

One request shape (`Muse.build_exec_request/4`) feeds **both** transports —
the local path turns it into argv, the HTTP path puts the same fields on the
wire, so the mirror is by construction, not by parallel maintenance:

| CLI invocation                  | HTTP request (`POST {url}/exec`)        |
|---------------------------------|-----------------------------------------|
| `--exec '<payload json>'`       | `"payload"`: the exact same JSON string  |
| `cd: working_dir`               | `"working_dir"`                          |
| `--rw` args (working_dir first, then profile `tool_rw`; empty when permissive) | `"rw"` list, same order |
| `--ro` args                     | `"ro"` list                              |
| `env: MUSE_ROOM_DEPTH=<depth>`  | `"env": {"MUSE_ROOM_DEPTH": "<depth>"}`  |
| (implicit)                      | `Authorization: Bearer <token>`          |

Response: body is what `--exec` prints on stdout (the ExecResult wrapper)
plus an `exit_code` field. `exit_code == 0` → body goes through the **same**
`unwrap_exec_output/1`; nonzero → the same `exec_error/2` (pulls `"error"`,
falls back to `exit=N: <slice>`). No second protocol was invented.

Judgment calls where the parallel muse-serve branch could land differently
(each is a one-line fix inside `Cranium.Muse.HTTP`):
- payload sent as the raw JSON *string* the CLI would receive (serve's brief
  says it marshals into the existing `--exec` entrypoint, which takes a string);
- exec failures expected as HTTP 200 + nonzero `exit_code` (non-200 is
  treated as a transport/daemon error);
- endpoint path assumed `/exec`.

Degradation posture is symmetric with a missing muse binary: unreachable
endpoint, timeout, 401, or missing token → `Logger.warning` +
`{:error, message}` → tool error to the agent. The session never crashes.

## Working-dir audit findings

What cranium does with working dirs locally:

- `Context.Router.resolve_working_dir/2` (used by `turn_assembler` each turn)
  probes the LOCAL filesystem: `File.dir?(projects_dir/<slug>)` for the
  room-matching logic, and on no match **creates** `/tmp/cranium/<slug>`
  locally. For a remote-exec room both are wrong: the room's project may
  exist only on the remote host (the primary use case — Xcode projects on
  obrien), and the /tmp fallback would create a junk local dir while sending
  the remote a path that means nothing.
- `Muse.exec` local path passes `cd: working_dir` to `System.cmd` (requires
  local existence). The remote path never touches the local filesystem — the
  dir rides the wire as a string.
- `Inference.NixEnv.env_for/1` stats a local `flake.nix` — but it has **no
  callers** on the muse exec path (supervision-tree only, for the old
  ClaudeCode backend); no change needed.
- `effects/handoff_writer.ex` and `effects/conversation_summarizer.ex`
  resolve working dirs for their own local shell-outs — part of the
  subagent/`claude`-binary problem, explicitly out of scope.
- `transport/openai.ex` uses an ephemeral local working dir — separate
  entrance, no profile exec routing today, left alone.

Smallest honest change: when the profile has `exec_endpoint`,
`turn_assembler` resolves the working dir as
`Router.remote_working_dir(room, endpoint.projects_dir)` —
`<remote projects_dir>/<slug>`, purely textual, no existence check, no
creation, no /tmp fallback. A wrong guess (e.g. a non-project chat room on a
remote-exec profile) surfaces as an honest tool error from the remote muse
rather than a silent local fallback.

**Observation (pre-existing, not fixed here):** `turn_assembler`'s
`resolve_profile/1` builds a lightweight `%Profile{}` for the turn but never
copies `tools_disabled` into it, so line ~531's `profile.tools_disabled`
always reads the struct default `false` — the `tools_disabled` YAML option
(commit 81b37ce) appears not to reach the turn. I threaded `exec_endpoint`
through that struct explicitly to avoid the same trap. Worth a look.

## Out of scope (known follow-ups, not built)

- **Subagent/delegate** (`lib/cranium/inference/agent/tools/subagent.ex`):
  shells out to the `claude` binary locally, bypassing Muse — on a
  remote-exec room subagents silently run on the wrong host and on a binary
  we thought we'd decoupled from. Untouched here (`git diff main -- …/subagent.ex`
  is empty); tracked separately.
- **Macros** — invoked as tools but executed by cranium; needs its own design.
- **Streaming exec** — v1 follow-up on the muse side too.
- **Worker discovery/registration** — endpoints are pinned config, not a fleet.
- Remote equivalent of the `/tmp/cranium/<slug>` fallback for non-project
  rooms (needs remote knowledge or serve-side mkdir semantics).

## Verification record

All run inside `nix develop` (Elixir 1.19.5 / OTP 28):

- `MIX_ENV=test mix test` — **857 tests, 0 failures.** No existing test was
  modified; changes to `config_test.exs` / `router_test.exs` /
  `fixtures/profiles.yaml` are purely additive (new describe blocks, one new
  fixture profile).
- `mix dialyzer` — **Total errors: 0** (passed).
- `mix compile --warnings-as-errors` — clean.
- New stub-server coverage (`test/cranium/muse/http_test.exs`, Req.Test plug —
  the repo's existing Req stubbing convention; Bypass is not in deps):
  happy path; grants/env/payload/working-dir fields asserted in the request
  body; bearer auth asserted; permissive-posture grant omission; response
  unwrap asserted byte-identical to `unwrap_exec_output` on the CLI path;
  nonzero exit → same error extraction as CLI; 401; timeout (names the
  configured ceiling); unreachable endpoint degrades to `{:error, _}`;
  token-from-env, token-from-file (trimmed), missing/unreadable token
  degrades without any HTTP attempt.
- Local path pinned (`test/cranium/muse_exec_local_test.exs`): a fake `muse`
  script prepended to PATH records argv/cwd/env — asserts the exact argv
  (`--rw`/`--ro` order, `--exec` payload), cwd, and `MUSE_ROOM_DEPTH` for
  sandbox, permissive, and default configs with **no** endpoint configured.
- Config validation (`config_test.exs`): fixture profile parses; literal
  token / missing url / missing token indirection / non-absolute
  projects_dir all raise at load.
- `subagent.ex` untouched: `git diff main -- lib/cranium/inference/agent/tools/subagent.ex` → empty.
- End-to-end against a scratch `muse serve` from the sibling branch: **not
  possible yet** — `burn/muse-serve` does not exist in `~/Projects/muse` at
  time of writing; the client was built to the brief's mapping with protocol
  knowledge isolated in `Cranium.Muse.HTTP` for the one-file fix.
