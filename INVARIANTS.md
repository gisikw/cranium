# Invariants

These are architectural contracts. They're not aspirational — they're load-bearing.
Violations are bugs, not style issues. No grandfather clauses.

If an invariant no longer serves the project, remove it explicitly with rationale.
Don't just ignore it.

## Code Organization

- Decision logic is pure: functions take data, return decisions, no I/O
- I/O is plumbing: thin orchestrators that gather data → call pure functions → act
- No multi-purpose functions: separate decision from effect
- New logic goes into testable functions first, not handler/framework layer

## File Size

- 500 lines max per file (ergonomic, not aesthetic)
- Split along behavioral seams, not alphabetically
- Tests mirror source files
- No grab-bag utility modules (`Utils`, `Helpers`)

## Naming

- Timestamps: `2006-01-02_15-04-05` (lexicographic, filesystem-safe)
- Module names match file paths (`Cranium.Ingress.Transcriber` → `lib/cranium/ingress/transcriber.ex`)

## Secrets

- No hardcoded secrets, tokens, PII, or infrastructure-specific details
- Environment-specific values come from runtime config or `.env` (gitignored)
- `.env.example` documents required vars with placeholders

## Policy

- Decisions that shape code are explicit (here), not implicit
- No "look at how X does it" as policy — write it down or it doesn't exist

---

## OTP Conventions

### Supervision

- The application supervisor uses `strategy: :rest_for_one` — if Store crashes,
  everything downstream restarts. If a transport crashes, epochs remain.
- Per-conversation epochs are supervised by a `DynamicSupervisor` — one epoch
  crash does not affect other conversations.
- Effects (handoffs, summaries) run as supervised `Task`s — crash isolation from
  the main pipeline.

### GenServer Discipline

- No blocking calls in `handle_info/2` — delegate to `Task` or `handle_continue`
- GenServer state is a struct, never a bare map
- Timeouts are explicit, never infinite (except for epoch idle — that uses
  `:hibernate` instead)
- `handle_call` is for synchronous queries; `handle_cast` is for fire-and-forget
  mutations; `handle_info` is for async messages and streaming chunks

### Process Communication

- Pipeline stages communicate via message passing, not direct function calls on
  shared state
- Streaming chunks use `send/2` with tagged tuples: `{:chunk, stream_id, data}`
- Stream completion uses `{:stream_end, stream_id}`
- Never use `Process.exit/2` for flow control — send explicit cancel messages

## Pipeline Contracts

### Stage Interface

Every pipeline stage implements the `Cranium.Stage` behaviour:
- `process/2` for complete-message processing
- `handle_chunk/3` and `handle_stream_end/2` for streaming (optional)

Stages that don't support streaming buffer input and process on completion.
Stages that support streaming may forward chunks incrementally.

### Streaming

- Every stage caches streamed input until downstream delivery is confirmed
- Cache is cleared on successful delivery, not on stream completion
- If streaming fails, cached data enables retry without upstream re-request
- Stream IDs are unique per invocation (not per conversation — concurrent
  retries must not collide)

### Backend Swappability

- STT, TTS, and LLM backends implement Elixir behaviours
- Backend modules are configured at the application level, not hardcoded
- No stage code may reference a specific backend implementation directly —
  always go through the behaviour
- Backend configuration is resolved at startup and injected into stage state

### Epoch Isolation

- At most one active epoch per conversation (enforced by Registry, not convention)
- Epoch crash in conversation A must not affect conversation B
- An epoch coordinates pipeline stages — it does not bypass them
- Epochs do not hold conversation history in process state — history lives
  in Store

## Storage Contracts

### Ecto

- All database access goes through `Cranium.Store` — no direct `Repo` calls
  from pipeline stages
- Migrations are forward-only (no rollback logic required, but migrations must
  be idempotent)
- Schemas define `@type t` for each entity

### Locking

- Store uses soft locks during active inference: reads are always allowed,
  writes queue behind active inference for the same conversation
- No database-level advisory locks — coordination happens in the Store GenServer
- Lock scope is per-conversation, never global

## Testing

### Strategy

- Pure decision functions get unit tests (fast, no GenServer needed)
- Stage GenServers get integration tests (start the stage, send messages,
  assert output)
- Backend behaviours have test implementations (in-memory, deterministic)
- Full pipeline tests use test backends (no network, no real LLM calls)
- Ecto tests use the sandbox adapter for isolation

### Requirements

- All public functions have typespecs
- Tests run with `async: true` unless they share mutable state (Ecto sandbox
  in shared mode)
- No `Process.sleep` in tests — use `assert_receive` with timeouts
- Test modules mirror source modules: `Cranium.Ingress` →
  `CraniumTest.IngressTest`
