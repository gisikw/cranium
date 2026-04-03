# Cranium v2

A streaming message pipeline that bridges conversational interfaces (Matrix, voice
clients) to LLM inference with full context management, tool use, and extensible
backends. Built as an Elixir OTP application for fault tolerance and runtime
introspection.

Cranium v2 replaces [cranium](../cranium/) — a Go bridge that delegates to Claude
Code subprocesses. v2 manages the LLM conversation directly via the Anthropic API,
gaining control over context assembly, streaming, tool execution, and epoch state.

## Glossary

These terms are settled and used consistently throughout the codebase.

| Term | Definition | Elixir module | Identifier |
|------|-----------|---------------|------------|
| **Conversation** | Persistent, named, indefinite interaction context. "nerve", "hearth", "personal-chat". Has a lifetime history. Survives everything. | — (identity, not a process) | `conversation_id` |
| **Epoch** | A span of continuous context within a conversation. Starts fresh (possibly with a handoff from the previous epoch). Ends on `!clear` or context exhaustion. Tracks saturation, turn count, accumulated messages. Persisted in Store, no dedicated GenServer. | `Cranium.Store.Epoch` (schema) | `epoch_id` |
| **Pass** | A single trip through the pipeline. One user message in, one assistant response out (may include multiple turns internally, but from the pipeline's perspective it's one pass). | — (pipeline traversal) | `stream_id` |
| **Dispatch** | Per-pass routing annotation stamped at ingest. Carries harness, model, renditions, and ephemeral flag. Providers receive the dispatch and key their caches on it. | `Cranium.Dispatch` | — |
| **Turn** | A single dispatch to the model within a pass. A pass with tool calls contains multiple turns (send context → get response → execute tool → re-send). | — (within Agent loop) | — |
| **Link** | A live connection between a client and a conversation. Receives output chunks, sends cancels, handles mode switching. When a client disconnects, the link drops but the conversation persists. | — (future) | — |
| **Stage** | A pipeline processing unit. GenServer implementing `Cranium.Stage` behaviour. Six top-level stages: Ingress, Context, Agent, Egress, Effects, Store. | `Cranium.Stage` | — |
| **Step** | A pure-function module within a stage. E.g., `CommandDetector` is a step within Ingress. | Step modules | — |
| **Transport** | Protocol adapter that lives outside the pipeline. Converts protocol-specific events to normalized messages (Matrix, Hearth). | `Cranium.Transport.*` | — |
| **Backend** | Hot-swappable service implementation behind a behaviour. STT (Whisper), TTS (Kokoro), LLM (Anthropic). | `Cranium.Backend.*` | — |
| **Handoff** | Summary document generated on `!clear`, capturing epoch context for the next epoch. | — (stored entity) | — |
| **Landscape** | Cross-conversation awareness — summaries from other active conversations injected into the system prompt. | — (assembled by PromptBuilder) | — |
| **Marker** | SCTE-style positional cue in the output stream. The model calls tools like `show`, `show_code`, `play_audio` that are intercepted and emitted as markers at the model's intended position. | — (stream event) | — |

### Deprecated Terms

These terms appear in cranium v1 and design documents but should **not** appear
in v2 code:

| Old term | Replacement |
|----------|-------------|
| `room_id` | `conversation_id` |
| `session` (as a domain concept) | `epoch` |
| `Session` (module) | `Epoch` |
| `room` (in cross-room context) | `conversation` |
| `RoomSummarizer` | `ConversationSummarizer` |
| `round` (as a domain concept) | `pass` |

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
| `Router` | Maps conversation to working directory, resolves project context |
| `PromptBuilder` | Assembles system prompt: identity document, conversation handoff, cross-conversation landscape |
| `TurnInjector` | Adds per-turn context injections — time-gap reminders, saturation warnings, interrupted context breadcrumbs, resume signals. Injections are conditional and position-sensitive. |
| `HistoryManager` | Retrieves and formats conversation history from Store |

#### Agent — Inference & Tool Management

Manages the LLM inference loop. This is a lightweight agent harness, not just an
API call — it handles multi-turn tool use within a single pass.

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
| `HandoffWriter` | On `!clear`, generates a handoff document via separate LLM call summarizing the epoch |
| `ConversationSummarizer` | Every N turns, generates a cross-conversation summary via separate LLM call |

#### Store — Persistence

Centralized storage with soft read/write locking during active inference.

| Entity | Purpose |
|--------|---------|
| Epochs | Per-conversation state: status, saturation, turn count, system prompt snapshot |
| Messages | Conversation history (role, content, token counts) |
| Handoffs | Conversation handoff documents for epoch continuity |
| Summaries | Cross-conversation awareness cache |

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

### Epoch Lifecycle

Each conversation has at most one active epoch at a time, tracked in Store.
Epoch state (saturation, turn count, cc_session_id) is persisted in the
database — there is no dedicated Epoch GenServer.

Per-conversation infrastructure (TurnAssembler + Harness) is started on
demand under `ConversationDynamicSupervisor`. TurnAssembler assembles
context, Harness runs inference, and `Persistence.Effects` handles
post-inference state mutations.

Epoch clearing (`!clear`) is handled directly by `Cranium.clear_epoch/1`:
cancel active inference, mark the old epoch as cleared, generate a handoff
document (async), and create a fresh epoch.

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

### Segment Manifest

Egress produces a **segment manifest** — a growing playlist of heterogeneous
content blocks that clients poll and consume. This is the delivery contract
between the pipeline and any client (Hearth, Matrix, CLI, future web UI).

The design borrows from HLS live playlists (sequence numbers, growing segment
list, end-of-stream marker) but uses JSON and supports mixed media types. It is
not an HLS/DASH/CMAF manifest — those formats assume homogeneous media segments
of known duration in a continuous playout timeline, which doesn't fit
heterogeneous LLM output.

#### Manifest Shape

```json
{
  "stream_id": "a1b2c3",
  "status": "streaming",
  "segments": [
    {
      "index": 0,
      "type": "utterance",
      "renditions": {
        "audio": {"url": "/v1/streams/a1b2c3/segments/0/audio", "mime": "audio/mp3", "duration": 1.2},
        "text": {"url": "/v1/streams/a1b2c3/segments/0/text", "mime": "text/plain"}
      }
    },
    {
      "index": 1,
      "type": "cue",
      "cue_type": "image",
      "data": {"url": "...", "alt": "A comparison table"}
    },
    {
      "index": 2,
      "type": "utterance",
      "renditions": {
        "audio": {"url": "/v1/streams/a1b2c3/segments/2/audio", "mime": "audio/mp3", "duration": 2.1},
        "text": {"url": "/v1/streams/a1b2c3/segments/2/text", "mime": "text/plain"}
      }
    }
  ]
}
```

`status` is `"streaming"` while the Agent is generating, `"complete"` after
`end_turn`. Clients poll the manifest and play/render new segments as they
appear.

#### Segment Types

- **`utterance`** — spoken/written content. Has renditions (see below).
- **`cue`** — SCTE-style marker from a tool call. Contains structured data
  for the client to render (image, code block, table, etc.). Cues are
  sequential segments, not sidecar annotations — LLM generation is
  autoregressive, so the model cannot speak and emit a tool call
  simultaneously. The natural ordering is always
  `utterance → cue → utterance`.

#### Renditions

Text and audio of the same utterance are **renditions**, not separate segments.
The client picks which rendition to consume based on its capabilities and the
user's preference.

- Matrix client: consumes `text` renditions, renders cues inline as markdown.
- Hearth: consumes `audio` renditions, renders cues as visual overlays.
- Airplane mode: text input, audio output — consumes `audio` renditions.

Renditions are independent of input modality. A request carries a
**disposition** — the set of output renditions the client wants:

```json
{"text": "...", "disposition": ["audio", "text"]}
```

#### TTS Cache

Audio renditions are served from a lazy in-memory cache (GenServer keyed by
`{stream_id, segment_index}`). Default behavior is lazy: audio is synthesized
on first GET for that segment. When the client's disposition includes `audio`,
Egress eagerly warms the cache as chunks arrive, so audio is ready before the
client polls.

Segments are evicted on first retrieval — replay is unlikely, and Kokoro
resynthesizes in ~350ms/sentence if needed. The cache is a buffer between
production and consumption, not durable storage. Text renditions don't need
caching; they're stored as conversation context, which we keep anyway.

#### HTTP Transport

##### Output (Manifest)

Three endpoints serve the segment manifest:

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/submit` | Accept input (text or audio), create epoch, return `stream_id` |
| `GET /v1/streams/:id/manifest` | Segment manifest with current status |
| `GET /v1/streams/:id/segments/:n/:rendition` | Individual segment content |

Client loop: submit → poll manifest → consume new segments → repeat until
`status: "complete"`.

##### Input Protocol

Input and output are symmetric: both are append-only, numbered, eventually
sealed. The output manifest is a journal of segments the server appends; the
input protocol is a journal of chunks the client appends.

The design borrows from broadcast remote-contribution models (Source-Connect,
Comrex). The client always captures locally — the local recording is the
source of truth. Streaming to the server is an optimization (enables early
transcription), not the delivery mechanism. If the stream is clean, the seal
triggers processing immediately. If chunks were lost, the client backfills
from its local cache.

```
Client                            Server
  |                                 |
  |-- POST /v1/input/start -------->|  → {take_id, stream_id}
  |                                 |
  |-- PUT /v1/input/:id/0 --------->|  (audio chunk, best-effort)
  |-- PUT /v1/input/:id/1 --------->|
  |-- PUT /v1/input/:id/2 ---X      |  (lost)
  |-- PUT /v1/input/:id/3 --------->|
  |                                 |
  |-- POST /v1/input/:id/done ----->|  → {missing: [2]}
  |                                 |
  |-- PUT /v1/input/:id/2 --------->|  → 2xx → server triggers inference
  |                                 |
  |-- GET /v1/streams/:sid/manifest |  (polling, segments appearing)
```

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/input/start` | Open a take. Returns `take_id` + `stream_id`. Params: `conversation_id`, `disposition`. |
| `PUT /v1/input/:id/:seq` | Append a numbered audio chunk. Best-effort — server acks but missing chunks are recoverable. |
| `POST /v1/input/:id/done` | Seal the take. Returns `{missing: [...]}` — empty list means all chunks received, inference starts. |

The `stream_id` returned on `/start` is the same one used to poll the output
manifest. The client doesn't need a second round-trip after backfilling — once
it sees 2xx on the last missing chunk, it starts polling the manifest. The
server detects completeness and triggers inference autonomously.

**Happy path**: all chunks land during streaming → `/done` returns
`{missing: []}` → inference already starting → poll manifest. Same effective
latency as an atomic POST.

**Degraded path**: some chunks lost → `/done` returns gap list → client
re-sends from local cache → inference starts on final 2xx.

**Text input**: continues to use `POST /v1/submit` directly — text is small,
atomic, and cheap to retry. The chunked protocol is for audio where upload
size and streaming STT make it worthwhile.

**Future transport upgrade**: the chunk protocol is transport-agnostic. The
initial implementation uses HTTP, but the semantics (numbered datagrams with
backfill) map directly to QUIC unreliable datagrams if sub-100ms transport
latency becomes necessary for real-time voice.

## Design Decisions

Captured from initial design review. These are directional, not final.

### Transport Agnosticism

Cranium v2 is **not** a Matrix bridge. Matrix may be one transport among several
(Hearth, future clients), but the pipeline core must be transport-agnostic.

### Inference Data Model

The internal message format currently mirrors Anthropic's API shape (role/content
pairs, multipart content blocks, tool_use/tool_result types). This is pragmatic
since Anthropic is the first backend. Other LLM backends (vLLM, Ollama) would
need a translation layer at the `Backend.LLM` boundary. This is future scope,
not a design flaw — the behaviour abstraction is in the right place.

### Stream Initialization

Every stage that accepts streaming input receives a `{:stream_start, stream_id,
metadata}` message before the first chunk arrives. This creates the buffer,
establishes context (conversation, epoch, mode), and lets the stage know what
it's receiving. The streaming protocol is: `stream_start → chunk* → stream_end`.

The `handle_stream_start/3` callback and `init_stream/3` helper are defined in
`Cranium.Stage`. All stages handle the full protocol. Structured buffers carry
metadata alongside chunks, with backward compatibility for legacy chunk-list
buffers.

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

1. ~~Stream initialization~~ — done.
2. ~~Vertical slice~~ — done.
3. ~~TTS integration~~ — done.
4. ~~STT integration~~ — done.
5. ~~Segment manifest + HTTP transport~~ — done.
6. ~~Persistence~~ — done. Ecto schemas, multi-turn context, full pipeline wired.
7. ~~Hearth integration~~ — done.
8. **Epoch lifecycle** — wire `!clear` to handoff generation, saturation tracking
9. **Agent tool execution** — handle tool_use stop reason, execute tools, re-enter
   inference loop. Requires ToolRouter registration and ToolExecutor dispatch.
10. **Input protocol** — chunked audio upload with take/seal/backfill semantics.
    See Input Protocol section above.

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
      conversation_summarizer.ex

    store.ex                       # Persistence stage
    store/
      repo.ex                     # Ecto Repo
      schemas/                    # Ecto schemas (epochs, messages, etc.)

    backend/                       # Hot-swappable backends
      stt.ex                      # Behaviour + Whisper impl
      tts.ex                      # Behaviour + Kokoro impl
      llm.ex                      # Behaviour + Anthropic impl

    transport/                     # Protocol adapters
      matrix.ex                   # Matrix sync + message handling
```
