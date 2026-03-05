# Cranium v2

A streaming message pipeline that bridges conversational interfaces (Matrix, voice
clients) to LLM inference with full context management, tool use, and extensible
backends. Built as an Elixir OTP application for fault tolerance and runtime
introspection.

Cranium v2 replaces [cranium](../cranium/) — a Go bridge that delegates to Claude
Code subprocesses. v2 manages the LLM conversation directly via the Anthropic API,
gaining control over context assembly, streaming, tool execution, and session state.

## Architecture

### Pipeline Overview

The pipeline is **fractal**: six top-level stages, each implemented as a GenServer
that decomposes into individual step modules. Messages flow left-to-right through
the pipeline; storage and side-effects operate asynchronously.

```
                           ┌──────────────────────────────────────────────────────────┐
                           │                      Pipeline                            │
                           │                                                          │
┌───────────┐    ┌─────────┴──┐    ┌──────────┐    ┌──────────┐    ┌──────────┐       │
│ Transport │───▶│  Ingress   │───▶│ Context  │───▶│  Agent   │───▶│  Egress  │───┐   │
└───────────┘    └────────────┘    └──────────┘    └──────────┘    └──────────┘   │   │
                                        ▲               │                         │   │
                                        │               ▼                         │   │
                                   ┌──────────┐    ┌──────────┐                   │   │
                                   │  Store   │◀───│ Effects  │◀──────────────────┘   │
                                   └──────────┘    └──────────┘                       │
                                        ▲                                             │
                                        └─────────────────────────────────────────────┘
```

Transports (Matrix, Hearth) live outside the pipeline. They convert protocol-specific
events into normalized messages, feed them to Ingress, and receive deliverable output
from Egress.

### Stage Reference

#### Ingress — Input Processing

Receives raw input from transports, normalizes it for downstream consumption.

| Step | Responsibility |
|------|---------------|
| `Deduplicator` | Prevents duplicate message processing (Matrix delivers events multiple times) |
| `Transcriber` | Routes audio to STT backend, produces text |
| `ImageProcessor` | Downloads and stores image attachments, formats references |
| `CommandDetector` | Recognizes control commands (`!clear`, `!cancel`) and emits pipeline signals rather than passing them as user messages |

#### Context — Context Assembly

Builds the full inference context from the normalized message and persisted state.

| Step | Responsibility |
|------|---------------|
| `Router` | Maps room/channel to working directory, resolves project context |
| `PromptBuilder` | Assembles system prompt: identity document, room handoff, cross-room landscape |
| `TurnInjector` | Adds per-turn context injections — time-gap reminders, saturation warnings, interrupted context breadcrumbs, resume signals. Injections are conditional and position-sensitive. |
| `HistoryManager` | Retrieves and formats conversation history from Store |

#### Agent — Inference & Tool Management

Manages the LLM inference loop. This is a lightweight agent harness, not just an
API call — it handles multi-turn tool use within a single invocation.

| Step | Responsibility |
|------|---------------|
| `Harness` | Core loop: send context → stream response → detect tool calls → execute → continue |
| `ToolRouter` | Maps tool names to executors, distinguishes real tools from markers |
| `ToolExecutor` | Runs real tool calls, returns results to the inference loop |
| `MarkerEmitter` | Intercepts SCTE-style marker tools (`show`, `show_code`, `play_audio`), returns fake success to the model, emits positional markers into the output stream |

#### Egress — Output Processing

Transforms agent output into deliverable formats for transports.

| Step | Responsibility |
|------|---------------|
| `Chunker` | Segments streaming output into deliverable units (sentence boundaries for TTS, paragraph breaks for text) |
| `Synthesizer` | Routes text chunks through TTS backend when in voice mode; pass-through in text mode |

#### Effects — Async Side-Effects

Work triggered by pipeline events but not on the critical path.

| Step | Responsibility |
|------|---------------|
| `HandoffWriter` | On `!clear`, generates a handoff document via separate LLM call summarizing the session |
| `RoomSummarizer` | Every N turns, generates a cross-room summary via separate LLM call |

#### Store — Persistence

Centralized storage with soft read/write locking during active inference.

| Entity | Purpose |
|--------|---------|
| Sessions | Per-room state: status, saturation, turn count, system prompt snapshot |
| Messages | Conversation history (role, content, token counts) |
| Handoffs | Room handoff documents for session continuity |
| Summaries | Cross-room awareness cache |

### Streaming Model

Every stage accepts streaming input through a uniform interface:

```elixir
# Push a chunk into a stage
Cranium.Stage.push(stage, stream_id, chunk)

# Signal that the stream is complete
Cranium.Stage.complete(stage, stream_id)
```

**Incremental stages** (Chunker, MarkerEmitter) forward chunks downstream as they
arrive. **Buffering stages** (PromptBuilder, HistoryManager) accumulate until
`complete/2`, then process the full input.

All stages cache streamed input until downstream delivery is confirmed. On streaming
failure, cached data enables retry without re-requesting from upstream. Cache is
cleared on successful delivery.

This design anticipates:
- STT backends that stream transcription while audio is still arriving (Voxtral Mini Realtime)
- LLM backends that support streaming prefill (vLLM)
- SSE from the Anthropic API, enabling output processing before inference completes

### Session Coordination

Each room has at most one active session at a time, enforced by
`Cranium.Session.Registry` (an Elixir `Registry` with unique keys).

A `Session` process coordinates the pipeline for a single invocation:

1. Ingress normalizes the incoming message
2. Context assembles the full inference payload
3. Agent runs inference (streaming)
4. Egress transforms and delivers output
5. Effects trigger as appropriate (handoffs, summaries)
6. Store is updated throughout

Sessions are spawned by transports and supervised by a `DynamicSupervisor`.

### Backend Swappability

STT, TTS, and LLM backends are defined as Elixir behaviours:

```elixir
# STT — Speech to Text
@callback transcribe(audio :: binary(), opts :: keyword()) ::
  {:ok, String.t()} | {:error, term()}

# TTS — Text to Speech
@callback synthesize(text :: String.t(), opts :: keyword()) ::
  {:ok, binary()} | {:error, term()}

# LLM — Language Model
@callback stream_chat(messages :: list(), opts :: keyword()) ::
  {:ok, stream_pid :: pid()} | {:error, term()}
```

Backends are configured at the application level and injected into stages. Swapping
Whisper for Voxtral means changing one config value.

Current backends:
- **STT**: Whisper (HTTP POST to whisper service)
- **TTS**: Kokoro (HTTP POST to kokoro service)
- **LLM**: Anthropic Messages API (SSE streaming)

### Cancel Model

Cancel signal from transport → Agent kills inference immediately → in-flight chunks
in Egress drain naturally → Store records where inference stopped → no rewinding
(tool side-effects are already committed).

Partial output is captured as an "interrupted context" breadcrumb, injected by
TurnInjector on the next invocation so the model has continuity.

### SCTE Markers

The model receives tools like `show`, `show_code`, `play_audio` that are display
triggers, not real operations. The Agent intercepts these tool calls, returns fake
success (`{"success": true}`), and emits a marker into the output stream at exactly
that position. The model's natural sense of timing **is** the timing data.

This lets rich media (code blocks, images, audio clips) appear in the output stream
at the position the model intended, without post-hoc alignment.

## Terminology

Settled in design review (2026-03-05). The codebase should use these terms
consistently. The initial scaffold uses older terms (`room_id`, `session`) in
many places — a renaming pass is needed.

- **Conversation** — persistent, named, indefinite. "nerve", "hearth",
  "personal-chat". Has a lifetime history. Survives everything. This is the
  durable identity of an ongoing interaction context.
- **Epoch** — a span of continuous context within a conversation. Starts fresh
  (possibly with a handoff from the previous epoch). Ends on `!clear` or context
  exhaustion. Tracks saturation, turn count, accumulated messages.
- **Round** — a single trip through the pipeline. One user message in, one
  assistant response out (may include multiple tool call loops internally, but
  from the pipeline's perspective it's one round).
- **Link** — a live connection between a client and a conversation. The link
  receives output chunks, sends cancels, handles mode switching. When a client
  disconnects, the link drops but the conversation persists.

## Design Decisions

Captured from initial design review. These are directional, not final.

### Transport Agnosticism

Cranium v2 is **not** a Matrix bridge. Matrix may be one transport among several
(Hearth, future clients), but the pipeline core must be transport-agnostic.
The initial scaffold carries some Matrix-specific naming (`room_id`, room-based
routing) inherited from cranium v1 — this needs a renaming pass to use
Conversation/Epoch/Round/Link terminology.

### Inference Data Model

The internal message format currently mirrors Anthropic's API shape (role/content
pairs, multipart content blocks, tool_use/tool_result types). This is pragmatic
since Anthropic is the first backend. Other LLM backends (vLLM, Ollama) would
need a translation layer at the `Backend.LLM` boundary. This is future scope,
not a design flaw — the behaviour abstraction is in the right place.

### Stream Initialization

Every stage that accepts streaming input needs a `{:stream_start, stream_id,
metadata}` message before the first chunk arrives. This creates the buffer,
establishes context (conversation, epoch, mode), and lets the stage know what
it's receiving. Without this, stages are blind on the first chunk. The initial
scaffold is missing this — it only has `{:chunk, ...}` and `{:stream_end, ...}`.

## Open Questions

Areas requiring design work as the project matures.

### Data Model

The storage schema needs careful design. Key tensions:
- Message history needs both full conversation replay and efficient windowed retrieval
- Handoffs/summaries are write-heavy, read-infrequent, but reads are latency-sensitive
  (they block epoch start)
- Epoch state updates are frequent during streaming (saturation tracking)
- Should we store raw tool call/result pairs, or summarized representations?
- How much of the Anthropic API message format do we preserve vs normalize?

**Current assumption**: Postgres with Ecto. Schema is minimal. Will need iteration.

### Tool Architecture

The Agent needs to support:
- Real tool execution (file operations, web searches, code execution)
- SCTE marker tools (intercepted, never executed)
- Skill dispatch (registered skill invocation)
- Tool approval routing (pause inference → ask user via link → resume)

The approval flow is interesting in OTP terms. Options:
- Agent process blocks on a `receive` waiting for approval
- State machine with `:awaiting_approval` state
- Separate approval process that the Agent monitors

### Context Window Management

When managing conversation history ourselves (not delegating to Claude Code):
- The Anthropic API returns token counts per response — track cumulative usage
- Implement our own summarization-based compaction? Or rely on the API's context
  window limits and let it error, then compact?
- Saturation tracking: computed from cumulative token counts vs model context limit

### Transport Strategy

Cranium v1 has a full Matrix client (mautrix-go). v2 needs to decide:
- Build a minimal Matrix transport? (sync loop, room state, send/edit, reactions)
- Hearth transport first, Matrix as optional add-on?
- External Matrix integration (plugin/bridge that connects via Link) vs built-in?

### Multi-Link Coordination

When multiple links connect to the same conversation:
- Shared epoch? Separate epochs?
- Output to all links simultaneously?
- Cancel from one link affects the others?

**Current assumption**: Defer this. Single-link-per-conversation initially.

### Next Steps

1. **Renaming pass** — `room_id` → `conversation_id`, `session` → `epoch`,
   add `{:stream_start, ...}` to the streaming protocol
2. **Vertical slice** — one real Anthropic API call with SSE streaming through
   Agent → Egress, emitting text. No transport, no TTS. Prove the core path
   works in `iex -S mix`
3. **Epoch lifecycle** — implement clear/handoff/saturation tracking with the
   new terminology

## Development

### Prerequisites

- Elixir 1.18+ / OTP 27+
- PostgreSQL 16+
- Nix (optional, for reproducible dev environment)

### Setup

```bash
# With nix
nix develop

# Fetch deps and setup database
mix deps.get
mix ecto.create
mix ecto.migrate

# Run tests
mix test

# Start dev server
iex -S mix
```

### Project Layout

```
lib/
  cranium.ex                       # Public API
  cranium/
    application.ex                 # OTP supervision tree
    stage.ex                       # Stage behaviour (shared streaming interface)

    session.ex                     # Per-room session coordinator
    session/registry.ex            # One-session-per-room enforcement

    ingress.ex                     # Input processing stage
    ingress/
      deduplicator.ex
      transcriber.ex
      image_processor.ex
      command_detector.ex

    context.ex                     # Context assembly stage
    context/
      router.ex
      prompt_builder.ex
      turn_injector.ex
      history_manager.ex

    agent.ex                       # Inference & tool management stage
    agent/
      harness.ex
      tool_router.ex
      tool_executor.ex
      marker_emitter.ex

    egress.ex                      # Output processing stage
    egress/
      chunker.ex
      synthesizer.ex

    effects.ex                     # Async side-effects stage
    effects/
      handoff_writer.ex
      room_summarizer.ex

    store.ex                       # Persistence stage
    store/
      repo.ex                     # Ecto Repo
      schemas/                    # Ecto schemas (sessions, messages, etc.)

    backend/                       # Hot-swappable backends
      stt.ex                      # Behaviour + Whisper impl
      tts.ex                      # Behaviour + Kokoro impl
      llm.ex                      # Behaviour + Anthropic impl

    transport/                     # Protocol adapters
      matrix.ex                   # Matrix sync + message handling
```
