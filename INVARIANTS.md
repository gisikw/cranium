# Invariants

These are architectural contracts. They're not aspirational — they're load-bearing.
Violations are bugs, not style issues. No grandfather clauses.

If an invariant no longer serves the project, remove it explicitly with rationale.
Don't just ignore it.

## Architecture: Actors, Not Pipelines

Cranium is an OTP application, not a web framework. The architecture is an ant
colony of independent actors communicating via messages — not a left-to-right
pipeline of data transformations. Four rules enforce this:

1. **Every module is a GenServer or is private to one.** No free-floating
   modules with public APIs that get composed from the outside. If it exists,
   it's an actor (GenServer) or it's internal logic that a specific actor owns.
   The actor is the unit of public interface.

2. **Actors communicate only through PubSub or call.** No importing
   another actor's internal modules. No reaching into another actor's data
   structures. Message passing or nothing. The only shared types are the ones
   in `Cranium.Messages` (the message vocabulary) and `Cranium.Store` (the
   persistence boundary).

3. **No `GenServer.cast`.** If you need a response, use `call`. If you're
   announcing an event, use PubSub (`send/2` via Registry dispatch). `cast`
   is the worst of both — point-to-point like a call but with no delivery
   guarantee and no backpressure. It hides failures. Use events or calls,
   never the middle ground.

4. **Pipelines live inside actors, never between them.** The `|>` operator
   and functional composition are for transforming data *within* a single
   actor's message handler (`handle_info`, `handle_call`, etc.). Pipelines
   never cross an actor boundary. If you're piping the output of one module
   into another at the top level, you're building a web app — stop and use
   message passing instead.

These rules exist because Elixir's community conventions push toward
Phoenix-style request/response pipelines, and the training data for AI
agents is overwhelmingly shaped by those conventions. Without explicit
guardrails, code will drift toward pipeline composition at the architecture
level. That drift is a bug in cranium, not a style preference.

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
- Module names match file paths (`Cranium.Media.Transcoder` → `lib/cranium/media/transcoder.ex`)

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
- Per-conversation infrastructure is supervised by `ConversationDynamicSupervisor` —
  one conversation's crash does not affect others.
- Effects (handoffs, summaries) run as supervised `Task`s — crash isolation from
  the main pipeline.

### GenServer Discipline

- No blocking calls in `handle_info/2` — delegate to `Task` or `handle_continue`
- GenServer state is a struct, never a bare map
- Timeouts are explicit, never infinite (except for epoch idle — that uses
  `:hibernate` instead)
- `handle_call` is for synchronous queries; `handle_info` is for async messages
  and streaming chunks

### Process Communication

- Actors communicate via message passing, not direct function calls on shared
  state
- Streaming chunks use `send/2` with tagged tuples: `{:chunk, stream_id, data}`
- Stream completion uses `{:stream_end, stream_id}`
- Never use `Process.exit/2` for flow control — send explicit cancel messages

### Registry Subscribers

- Any GenServer that subscribes to a `Cranium.Events` topic **must** have a
  catch-all `handle_info(_msg, state)` clause. Registry topics are shared buses —
  the event vocabulary will grow, and a missing clause is a `FunctionClauseError`
  crash on the next vocabulary expansion.
- When adding a new event to the `Cranium.Events` vocabulary, audit all subscribers
  for each broadcast scope used (`stream_raw`, `conversation`, `global`). Verify
  every subscriber either handles or ignores the new shape. This is a required
  step, not a nice-to-have.

## Actor Contracts

### Streaming

- Stream IDs are unique per invocation (not per conversation — concurrent
  retries must not collide)
- Streaming chunks are messages (`{:chunk, stream_id, data}`), not function
  returns. Actors that produce or consume streams communicate via PubSub.

### Backend Swappability

- STT, TTS, and LLM backends implement Elixir behaviours
- Backend modules are configured at the application level, not hardcoded
- No actor may reference a specific backend implementation directly —
  always go through the behaviour
- Backend configuration is resolved at startup and injected into actor state

### Epoch Isolation

- At most one active epoch per conversation (enforced by Registry, not convention)
- Epoch crash in conversation A must not affect conversation B
- Epochs do not hold conversation history in process state — history lives
  in Store

## Storage Contracts

### Ecto

- Production database is `cranium_prod` — not `cranium_dev`. When querying
  the running service's data, use `psql -U postgres -d cranium_prod`.
- All database access goes through `Cranium.Store` — no direct `Repo` calls
  from other actors
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
- Actor GenServers get integration tests (start the actor, send messages,
  assert output)
- Backend behaviours have test implementations (in-memory, deterministic)
- Full system tests use test backends (no network, no real LLM calls)
- Ecto tests use the sandbox adapter for isolation

### Requirements

- All public functions have typespecs
- Tests run with `async: true` unless they share mutable state (Ecto sandbox
  in shared mode)
- No `Process.sleep` in tests — use `assert_receive` with timeouts
- Test modules mirror source modules: `Cranium.Media.Transcoder` →
  `Cranium.Media.TranscoderTest`
