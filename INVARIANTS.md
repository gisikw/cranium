# Invariants

Architectural contracts for the cranium codebase. Violations are bugs, not
style issues. If an invariant no longer serves the project, remove it explicitly
with rationale. Don't just ignore it.

## Specifications and Tests

- **Every behavior has a spec.** Behavioral specs live in `spec/*.feature`
  (gherkin syntax). These are the source of truth for what the system promises
  to do.
- **Every spec has a test.** Go tests in `_test.go` files are the verification
  layer. A spec without a corresponding test is an unverified claim.
- **Spec before code.** Every new behavior gets a spec before or alongside the
  implementation, not after.

## Build

- **`-tags goolm` is required.** We use the pure-Go OLM implementation, not
  the C libolm. This applies to both `go build` and `go test`. The canonical
  commands are in the justfile.
- **Version is injected via ldflags from `git rev-parse --short HEAD`.** No
  hardcoded version strings.

## Concurrency

- **Async persistence is non-blocking with explicit lifecycle.** SessionStore
  mutations fire async saves via `go s.save()`. In tests, this means waiting
  for save completion before temp directory cleanup (`settleAsync` pattern).
- **Room-level coordination is lock-free.** Per-room dedup and active
  invocation tracking use `sync.Map` with `LoadOrStore`/`CompareAndSwap`.
- **One active agent invocation per room.** Enforced by the `activeRooms`
  sync.Map. Concurrent messages to the same room are dropped, not queued.

## Code Organization

- **Decision logic is pure.** Functions that make decisions take data in and
  return decisions out. No Matrix client calls, no file I/O, no `*Bridge`
  receiver, no goroutines.
- **I/O is plumbing, not logic.** `*Bridge` methods that touch the Matrix
  client or invoke agents are thin orchestrators: gather data, call pure
  decision functions, act on results.
- **New logic goes into testable functions first.** Write the decision
  function, write the test, then wire it into the bridge.
- **No multi-purpose functions.** Separate the decision from the effect.

## Agent Invocation Lifecycle

- **`invokeClaude` is the single entry point.** All agent invocations flow
  through `(*Bridge).invokeClaude`. No code should duplicate the invocation
  setup or call agent CLIs directly.
- **Resume invocations use `invokeResumeInBackground`.** Any code that needs
  to trigger an agent in the background must call `invokeResumeInBackground`.
- **Session lifecycle is managed by the entry point.** Setting new session IDs,
  marking invoked timestamps, updating saturation state — these happen in the
  invocation path, not in callers.

## File Size

- **500 lines max per file.** Ergonomic constraint for agent readability.
- **Split along behavioral seams, not alphabetically.**
- **Tests mirror source files.** `session.go` -> `session_test.go`.
- **`main.go` is just `main()`.** Flag parsing, signal handling, startup.

## Error Handling

- **Log and continue, don't crash.** Callosum is a long-running daemon.
  Failures in side effects (typing indicators, pins, summaries) are logged
  and swallowed.
- **The critical path is message -> agent -> response.** That path must
  succeed or visibly fail to the user. Everything else is best-effort.

## Naming and File Layout

- **`slugify()` is the single source of truth for room -> filesystem mapping.**
- **Timestamps in filenames use `2006-01-02_15-04-05` format.**
- **Specs are named for the behavioral domain, not the implementation.**

## Time and Clock Access

- **All time access goes through `b.now()`, not `time.Now()`.** Injectable
  clock for testability.
- **Exception: `main.go` may call `time.Now()` during initialization.**
- **Pure decision functions take time as a parameter.**

## Parameterization

- **Callosum does not own identity.** Identity (system prompts, persona
  configuration) is injected by the caller via configuration paths. Callosum
  reads identity files; it does not define them.
- **Storage paths are configurable.** Handoffs, summaries, and session state
  are relative to a base directory passed at startup, not hardcoded.
- **Agent dispatch is pluggable.** The `ClaudeInvoker` interface abstracts
  agent invocation. New agent backends (Crane, local models) implement the
  same interface.

## Secrets

- No hardcoded secrets, tokens, PII, or infrastructure-specific details.
- Environment-specific values come from `.env` (gitignored).
- `.env.example` documents required vars with placeholders.

## Policy

- **Decisions that shape code are explicit, not implicit.** If a convention
  matters, it's written here. If it's not here, it's not a convention.
