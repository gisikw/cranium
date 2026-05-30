# Cranium

An OTP application that bridges conversational interfaces (Hearth voice client,
Matrix via headjack) to LLM inference with context management, profile-based
backend routing, and streaming output. Built for fault tolerance and runtime
introspection.

Cranium is the inference and context layer. Matrix protocol integration is
handled externally by [headjack](../headjack/), which forwards messages to
cranium's HTTP API. Hearth (iOS) connects directly. An OpenAI-compatible API
is also available for third-party clients.

## Glossary

These terms are settled and used consistently throughout the codebase.

| Term | Definition | Elixir module | Identifier |
|------|-----------|---------------|------------|
| **Conversation** | Persistent, named, indefinite interaction context. "roost", "cranium", "exo-local". Has a lifetime history. Survives everything. | — (identity, not a process) | `conversation_id` |
| **Epoch** | A span of continuous context within a conversation. Starts fresh (possibly with a handoff from the previous epoch). Ends on `!clear` or context exhaustion. Tracks saturation, turn count, accumulated messages. Persisted in Store, no dedicated GenServer. | `Cranium.Store.Epoch` (schema) | `epoch_id` |
| **Pass** | A single trip through the system. One user message in, one assistant response out (may include multiple turns internally). | — (pipeline traversal) | `stream_id` |
| **Profile** | Named configuration binding a backend, model, identity document, and saturation thresholds. Resolved per-pass from the request's `profile` field, falling back to the default. | `Cranium.Config.Profile` | profile name |
| **Turn** | A single dispatch to the model within a pass. A pass with tool calls contains multiple turns (send context → get response → execute tool → re-send). | — (within Agent loop) | — |
| **Transport** | Protocol adapter that accepts input and delivers output. HTTP is the sole transport; Matrix integration is handled externally by bridge clients. | `Cranium.Transport.HTTP` | — |
| **Backend** | Hot-swappable service implementation behind a behaviour. STT (Whisper), TTS (ExoVoice), LLM (Claude Code, Anthropic, Ollama). | `Cranium.Backend.*` | — |
| **Handoff** | Summary document generated on `!clear`, capturing epoch context for the next epoch. | — (stored entity) | — |
| **Macro** | A JSON-defined instruction unit with six axes (trigger, advertising, lifecycle, learning, revision, disposition) and a body (prompt, script, or sequence). Loaded from disk, evaluated per-turn by the macro engine. | `Cranium.Macro.*` | macro name |
| **Landscape** | Cross-conversation awareness — summaries from other active conversations injected into the system prompt. | `Cranium.Inference.Landscape` | — |
| **Marker** | SCTE-style positional cue in the output stream. The model calls tools like `show`, `show_code`, `play_audio` that are intercepted and emitted as markers at the model's intended position. | — (stream event) | — |
| **Take** | A chunked audio input session. Opened, filled with numbered chunks, sealed, then assembled for transcription. | `Cranium.Transport.SegmentRegistry` | `take_id` |

### Deprecated Terms

These terms appear in legacy code and design documents but should **not** appear
in current code:

| Old term | Replacement |
|----------|-------------|
| `room_id` | `conversation_id` |
| `session` (as a domain concept) | `epoch` |
| `room` (in cross-room context) | `conversation` |
| `round` (as a domain concept) | `pass` |
| `pipeline` / `stage` (as architectural terms) | actor / module |

## Architecture

### Actor Model

Cranium is an OTP actor system, not a pipeline. Independent GenServers
communicate via PubSub (Registry-based) and direct calls. See INVARIANTS.md
for the four rules that enforce this.

```
┌─────────────────┐
│  Transport.HTTP  │  Accepts input, serves manifests/segments/SSE
└────────┬────────┘
         │ {:pass_header, ...} + {:text_input, ...} via PubSub
         ▼
┌─────────────────┐     ┌──────────────┐
│  TurnAssembler   │────▶│   Harness    │  Per-conversation, started on demand
│  (context build) │     │  (inference) │  under ConversationDynamicSupervisor
└─────────────────┘     └──────┬───────┘
         ▲                      │
         │                      ▼
┌────────┴────────┐     ┌──────────────┐     ┌──────────────────┐
│     Store       │◀────│  PassReactor │     │ OutputSegmenter  │
│  (Ecto/Postgres)│     │  (effects)   │     │ + Manifest       │
└─────────────────┘     └──────────────┘     │  (delivery)      │
                                             └──────────────────┘
                                              ▲
                                              │ segments, TTS
                                        ┌─────┴──────┐
                                        │   Media    │
                                        │ (TTS, STT) │
                                        └────────────┘
```

### Request Flow

1. **Transport** (`Transport.HTTP`) receives input via `/v1/submit` (text) or
   `/v1/input/*` (chunked audio). Broadcasts a `PassHeader` + content message.
2. **TurnAssembler** (per-conversation GenServer) catches the broadcast.
   Resolves the profile → backend/model/identity. Assembles system prompt,
   conversation history, landscape, turn injections. Emits `{:turn_ready, turn}`.
3. **Harness** (per-conversation GenServer) receives the turn. Dispatches to
   the resolved LLM backend. Streams response chunks via PubSub. Handles
   multi-turn tool use loops.
4. **OutputSegmenter** subscribes to stream events, segments output at sentence
   or paragraph boundaries for TTS, and writes to the segment **Manifest**.
5. **PassReactor** (effects) updates epoch state (saturation, turn count,
   session ID), triggers periodic summarization and handoff generation.
6. **Store** persists epochs, messages, summaries, and handoffs in Postgres.

### Profile System

Profiles are defined in `~/.config/cranium/profiles.yaml`:

```yaml
default: exo
ollama_url: http://localhost:11434

profiles:
  exo:
    backend: claudecode
    model: claude-opus-4-6
    identity: /path/to/EXO.md
    context_window: 200000
    saturation_warn: 50
    saturation_critical: 80

  exo-local:
    backend: ollama
    model: gemma4-heretic
    identity: /path/to/EXO.md
    thinking: false
    context_window: 262144
```

The `profile` field in a request selects the profile. If absent, the default
profile is used. Each profile controls:

- **backend** — which LLM backend module handles inference
- **model** — model identifier passed to the backend
- **identity** — system prompt / identity document path
- **thinking** — whether to request extended thinking (Ollama)
- **context_window** / **saturation_warn** / **saturation_critical** — per-profile
  context management thresholds
- **openai_system_mode** — how OpenAI-compat client system messages combine with
  the profile identity (`:replace`, `:prepend`, `:append`)
- **private** — if true, skip cross-conversation summarization for this profile

### LLM Backends

Three backends implement the `Cranium.Backend.LLM` behaviour:

| Backend | Module | Mode |
|---------|--------|------|
| **Claude Code** | `Backend.LLM.ClaudeCode` | Spawns a Claude Code CLI subprocess. Supports session resume (stateful) and oneshot (ephemeral). Provides MCP tool server for markers. |
| **Anthropic** | `Backend.LLM.Anthropic` | Direct Anthropic Messages API with SSE streaming. Stateless. |
| **Ollama** | `Backend.LLM.Ollama` | Ollama HTTP API (`/api/chat`). Supports local and remote instances. Stateless. |

Claude Code is the primary backend — it handles tool execution, file access,
and session continuity natively. Anthropic and Ollama are stateless backends
that receive the full assembled context each pass.

### Tool System

Non-CC backends use a tool kernel for sandboxed tool execution:

| Source | Resolution |
|--------|-----------|
| **Markers** (`show`, `show_code`, `play_audio`) | Intercepted by `MarkerEmitter`, returns fake success, emits positional marker into stream |
| **clear_context** | Triggers `Cranium.clear_epoch/2` with optional continuation argument |
| **Muse tools** | Delegated to the [muse](../muse/) tool kernel via `muse --rw <dir> --exec <payload>`, sandboxed to the conversation's working directory |
| **Built-in tools** (e.g. `subagent`) | Registered in `ToolRouter`, executed by `ToolExecutor` |

Muse tool definitions are loaded at boot via `muse --tools` and advertised to
backends in Anthropic tool shape. If muse is not on PATH, tool loading is
skipped gracefully.

### Macro Engine

The macro engine is a declarative instruction management system that runs
alongside the plugin system. It loads JSON definitions from disk, evaluates
triggers per-turn, manages reducer-style state, and integrates with the
injection pipeline and tool router. The formal spec is at `specs/macro.allium`.

A macro is defined by **six axes** and a **body type**:

| Axis | Values | Controls |
|------|--------|----------|
| **Trigger** | `explicit`, `match`, `ambient`, `passive` | How the macro fires |
| **Advertising** | `listed`, `discoverable`, `searchable`, `hidden` | Visibility to the model |
| **Lifecycle** | `turn`, `epoch`, `session`, `condition`, `parent` | How long it stays active |
| **Learning** | `none`, `self_report`, `sidecar`, `structured` | How completion is tracked |
| **Revision** | `never`, `session_end`, `on_condition` | Whether it self-modifies |
| **Disposition** | `foreground`, `background`, `gated` | Who has the floor |

| Body Type | What It Does |
|-----------|-------------|
| **prompt** | Template text injected into context (with optional XML tag + priority) |
| **script** | Shell command executed by the harness (with timeout, env vars) |
| **sequence** | Ordered chain of child macros with shared tmpdir |

#### Macro Definition Shape

```json
{
  "name": "example",
  "description": "What this macro does",
  "version": 1,
  "trigger": "match",
  "match_config": {
    "patterns": ["keyword", "/regex-pattern/"],
    "once": true
  },
  "advertising": "hidden",
  "lifecycle": "session",
  "learning": "none",
  "revision": "session_end",
  "revision_config": {
    "prompt": "Review this definition: %{definition}\nConversation: %{messages}"
  },
  "disposition": "background",
  "body_type": "prompt",
  "prompt_body": {
    "text": "Injected context with %{template_variables}",
    "tag": "glossary",
    "priority": 15
  },
  "input_schema": {
    "type": "object",
    "properties": {
      "term": {"type": "string", "description": "The term to look up"}
    },
    "required": ["term"]
  },
  "tags": ["optional", "searchable-tags"]
}
```

Optional fields by axis configuration:

- `match_config` — required when trigger=match. `patterns` are literal
  (word-boundary, case-insensitive) or `/regex/`. `once` prevents re-firing.
- `discoverable_config` — required when advertising=discoverable. `keywords`
  trigger one-time discovery announcements.
- `sidecar_config` — required when learning=sidecar. Async evaluation via
  cheap model with `interval` turn gating. Template vars: `%{conditions}`,
  `%{lookback}`.
- `revision_config` — required when revision != never. Template vars:
  `%{definition}`, `%{messages}`.
- `input_schema` — JSON Schema for tool input. When present, used verbatim for
  the tool definition. When absent, prompt macros auto-derive from template vars,
  script/sequence macros get a generic `input` string. Tool input keys are passed
  to scripts as `MACRO_<KEY>` env vars.
- `conditions` — list of `{description, section}` for lifecycle=condition macros.
- `children` — nested macro definitions (lifecycle=parent, activated with parent).
- `tools` — tool definitions exposed while macro is active.
- `state_schema` — JSON schema for reducer-style persistent state.
- `script_body` — `{command, timeout_seconds, sandbox}` for body_type=script.
- `sequence_body` — `{steps: [{name} | {inline}], on_failure: halt|skip|abort}`
  for body_type=sequence.

#### Engine Integration

- **TurnAssembler** calls `Macro.Engine.evaluate_turn/1` during context build.
  Trigger evaluation, condition activation, and prompt injection happen here.
- **PassReactor** calls `Macro.Engine.after_pass/1` to dispatch sidecar
  evaluations for active condition macros.
- **Epoch end** calls `Macro.Engine.on_epoch_end/1` to dispatch revision for
  macros with revision=session_end.
- **ToolRouter** queries `Macro.Engine.tool_definitions_for_room/1` for
  explicit-trigger macros. Tool names are prefixed `macro_` to avoid collisions.

#### Patterns

The engine subsumes several existing patterns into a single primitive:

| Pattern | Axes | Example |
|---------|------|---------|
| **Skill** | explicit, listed, turn, prompt | "Run the handoff generator" |
| **Glossary** | match, hidden, session, prompt, revision=session_end | "Inject k8s context on mention" |
| **Agenda** | explicit, listed, condition, sidecar, prompt+children | "Run standup with tracked items" |
| **Script tool** | explicit, discoverable, turn, script | "Deploy on keyword mention" |
| **Pipeline** | explicit, searchable, turn, sequence | "Multi-step deploy+verify" |

### Module Reference

#### Inference

| Module | Responsibility |
|--------|---------------|
| `Inference.TurnAssembler` | Per-conversation GenServer. Correlates PassHeaders with content, resolves profiles, assembles full inference context (system prompt, history, landscape, injections). |
| `Inference.Harness` | Per-conversation GenServer. Receives assembled turns, dispatches to LLM backend, manages streaming, computes saturation. |
| `Inference.Agent` | Runs the inference loop for a single pass. Handles multi-turn tool use (tool call → execute → re-enter). |
| `Inference.History` | Retrieves and formats conversation history from Store for context assembly. |
| `Inference.Landscape` | Builds cross-conversation awareness from stored summaries. |
| `Inference.SystemPrompt` | Assembles the system prompt from identity doc, handoff, and injections. |
| `Inference.Conversation` | Starts and manages per-conversation supervisor (TurnAssembler + Harness). |
| `Inference.NixEnv` | ETS cache for Nix devShell PATH resolution (used by ClaudeCode backend). |

#### Context

| Module | Responsibility |
|--------|---------------|
| `Context.Router` | Maps conversation_id to working directory (project dirs or `/tmp/cranium/<slug>`). |
| `Context.TurnInjector` | Adds per-turn context injections — time-gap reminders, saturation warnings, interrupted context breadcrumbs, cross-room context. |

#### Agent Internals

| Module | Responsibility |
|--------|---------------|
| `Inference.Agent.Harness` | Core agent loop within a pass: stream response → detect tool calls → execute → continue. |
| `Inference.Agent.Tool` | Tool behaviour — contract for executable tools. |
| `Inference.Agent.ToolRouter` | Maps tool names to executors, distinguishes real tools from markers and muse delegations. |
| `Inference.Agent.ToolExecutor` | Runs tool calls, returns results to the agent loop. |
| `Inference.Agent.MarkerEmitter` | Intercepts SCTE-style marker tools, returns fake success, emits positional markers into the output stream. |
| `Inference.Agent.Tools.Bash` | Shell command execution tool. |
| `Inference.Agent.Tools.Subagent` | Spawns sub-agent inference passes via `claude -p`. |

#### Macro Engine

| Module | Responsibility |
|--------|---------------|
| `Macro.Engine` | Coordination layer — evaluates triggers, activates macros, returns injections, manages tool registration. Lifecycle hooks: `evaluate_turn`, `after_pass`, `on_epoch_end`. |
| `Macro.Definition` | Struct + JSON parser. Validates six axes, body types, configs, children (recursive). |
| `Macro.Registry` | ETS-backed GenServer. Loads JSON files from `macros_path`, indexes by trigger and advertising, supports hot reload via file watcher. |
| `Macro.State` | Two-tier state: persistent (per-room, per-macro, disk-backed) and session (ETS, ephemeral). Atomic writes. |
| `Macro.Trigger` | Evaluates match/ambient triggers against message text. Manages seen-sets and discovery. |
| `Macro.Matcher` | Pattern compilation — literal strings become word-boundary regexes, `/regex/` strings compile raw. |
| `Macro.Executor` | Executes prompt (template resolution + tag wrapping), script (shell + env vars + timeout), and sequence (ordered steps + tmpdir) bodies. |
| `Macro.Sidecar` | Async condition evaluation via cheap model. ETS-backed in-flight tracking with interval gating. |
| `Macro.Revision` | Epoch-end self-modification. Calls sidecar model with definition + messages, atomic file rewrite on update. |

#### Effects

| Module | Responsibility |
|--------|---------------|
| `Effects.PassReactor` | Reacts to pass completion: updates epoch state (saturation, turn count, cc_session_id), triggers summarization. |
| `Effects.HandoffWriter` | On `!clear`, generates a handoff document via separate LLM call summarizing the epoch. |
| `Effects.ConversationSummarizer` | Periodically generates cross-conversation summaries for the landscape. |
| `Effects.ContinuationDispatcher` | After handoff completes, auto-dispatches a new pass if the cleared epoch carried a continuation. |

#### Media

| Module | Responsibility |
|--------|---------------|
| `Media.Transcoder.Transcriber` | Routes audio to STT backend (Whisper), produces text. |
| `Media.TakeCollector` | Manages chunked audio assembly — correlates transcription results with takes. |
| `Media.OutputSegmenter` | Segments streaming output into deliverable units (sentence boundaries for TTS, paragraphs for text). |
| `Media.TTS.Cache` | In-memory cache for synthesized audio segments, keyed by `{stream_id, segment_index}`. |
| `Media.TTS.Warmer` | Eagerly synthesizes TTS for audio-disposition streams as segments arrive. |

#### Transport

| Module | Responsibility |
|--------|---------------|
| `Transport.HTTP` | Plug router. Handles `/v1/submit`, `/v1/input/*`, `/v1/streams/*`, `/v1/conversations/*`, SSE and OpenAI-compat endpoints. |
| `Transport.OpenAI` | OpenAI-compatible chat completions handler (`/v1/chat/completions`, `/v1/models`). |
| `Transport.Manifest` | Event-driven segment manifest — growing playlist of heterogeneous content blocks. |
| `Transport.SegmentRegistry` | Tracks chunked audio input takes: open, buffer chunks, seal, detect completeness. |

#### Store

| Entity | Purpose |
|--------|---------|
| Epochs | Per-conversation state: status, saturation, turn count, cc_session_id, profile, continuation |
| Messages | Conversation history (role, content, token counts) |
| Summaries | Cross-conversation awareness cache |

### Epoch Lifecycle

Each conversation has at most one active epoch at a time, tracked in Store.
Epoch state (saturation, turn count, cc_session_id) is persisted in the
database — there is no dedicated Epoch GenServer.

Per-conversation infrastructure (TurnAssembler + Harness) is started on
demand under `ConversationDynamicSupervisor`. TurnAssembler assembles
context, Harness runs inference, and `PassReactor` handles
post-inference state mutations.

Epoch clearing (`!clear`) is handled directly by `Cranium.clear_epoch/1`:
cancel active inference, mark the old epoch as cleared, generate a handoff
document (async), and create a fresh epoch. If the `clear_context` tool
provided a continuation argument, `ContinuationDispatcher` auto-sends it
as a new pass once the handoff completes.

### Cancel Model

Cancel signal from transport → Harness kills the Agent immediately → in-flight
output segments drain naturally → Store records where inference stopped → no
rewinding (tool side-effects are already committed).

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

The output system produces a **segment manifest** — a growing playlist of
heterogeneous content blocks that clients poll and consume. This is the delivery
contract between the system and any client (Hearth, future web UI).

The design borrows from HLS live playlists (sequence numbers, growing segment
list, end-of-stream marker) but uses JSON and supports mixed media types.

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
        "audio": {"url": "/v1/streams/a1b2c3/segments/0/audio", "mime": "audio/mp3"},
        "text": {"url": "/v1/streams/a1b2c3/segments/0/text", "mime": "text/plain"}
      }
    },
    {
      "index": 1,
      "type": "cue",
      "cue_type": "image",
      "data": {"url": "...", "alt": "A comparison table"}
    }
  ]
}
```

#### Segment Types

- **`utterance`** — spoken/written content. Has renditions (see below).
- **`cue`** — SCTE-style marker from a tool call. Contains structured data
  for the client to render (image, code block, audio clip).

#### Renditions

Text and audio of the same utterance are **renditions**, not separate segments.
The client picks which to consume based on capabilities and user preference.

A request carries a **disposition** — the set of output renditions the client wants:

```json
{"text": "...", "disposition": ["audio", "text"]}
```

#### TTS Cache

Audio renditions are served from a lazy in-memory cache (GenServer keyed by
`{stream_id, segment_index}`). When the client's disposition includes `audio`,
the TTS Warmer eagerly synthesizes as segments arrive. Segments are evicted
on first retrieval.

### HTTP API

#### Input

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/submit` | Accept text or audio input. Params: `conversation_id`, `text`, `profile`, `disposition`, `origin`, `model`, `ephemeral`. Returns `stream_id`. |
| `POST /v1/input/start` | Open a chunked audio take. Params: `conversation_id`, `profile`, `disposition`, `origin`. Returns `take_id` + `stream_id`. |
| `PUT /v1/input/:id/:seq` | Append numbered audio chunk. |
| `POST /v1/input/:id/done` | Seal a take. Returns `{missing: [...]}`. |

#### Output

| Endpoint | Purpose |
|----------|---------|
| `GET /v1/streams/:id/manifest` | Segment manifest with current status. |
| `GET /v1/streams/:id/segments/:n/text` | Text rendition of segment N. |
| `GET /v1/streams/:id/segments/:n/audio` | Audio rendition of segment N. |
| `GET /v1/streams/:id/events` | Per-stream SSE (single pass). |

#### Lifecycle

| Endpoint | Purpose |
|----------|---------|
| `GET /v1/conversations/:id` | Conversation metadata: epoch status, saturation, turn count, session ID. |
| `GET /v1/conversations/:id/events` | Conversation-level SSE (all passes). |
| `GET /v1/events` | Global SSE firehose (all conversations). |
| `POST /v1/clear` | Clear the active epoch for a conversation. |

#### OpenAI-Compatible

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/chat/completions` | Chat completions. Model field selects a profile. Supports streaming. |
| `GET /v1/models` | Lists available profiles as models. |

Ephemeral — no history persistence, no landscape injection. The `openai_system_mode`
profile field controls how client system messages combine with the profile identity.

### Input Protocol

The chunked audio protocol borrows from broadcast remote-contribution models
(Source-Connect, Comrex). The client captures locally — the local recording is
the source of truth. Streaming to the server enables early transcription. If
chunks are lost, the client backfills from its local cache after seal.

```
Client                            Server
  |                                 |
  |-- POST /v1/input/start -------->|  -> {take_id, stream_id}
  |                                 |
  |-- PUT /v1/input/:id/0 --------->|  (audio chunk, best-effort)
  |-- PUT /v1/input/:id/1 --------->|
  |-- PUT /v1/input/:id/2 ---X      |  (lost)
  |-- PUT /v1/input/:id/3 --------->|
  |                                 |
  |-- POST /v1/input/:id/done ----->|  -> {missing: [2]}
  |                                 |
  |-- PUT /v1/input/:id/2 --------->|  -> 2xx -> server triggers inference
  |                                 |
  |-- GET /v1/streams/:sid/manifest |  (polling, segments appearing)
```

## Development

### Prerequisites

- Elixir 1.19+ / OTP 27+
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
  cranium.ex                            # Public API (clear_epoch, cancel)
  cranium/
    application.ex                      # OTP supervision tree
    config.ex                           # Profile system (YAML → ETS)
    events.ex                           # PubSub (Registry-based)
    stage.ex                            # Stage behaviour
    dispatch.ex                         # Per-pass routing annotations
    drain.ex                            # Graceful shutdown coordination
    messages.ex                         # Message vocabulary (PassHeader, TextInput, Segment, etc.)
    muse.ex                             # Muse tool kernel bridge (load + exec)
    release.ex                          # Mix release tasks

    inference/
      turn_assembler.ex                 # Context assembly (per-conversation)
      harness.ex                        # Inference dispatch (per-conversation)
      agent.ex                          # Single-pass agent loop
      agent/
        harness.ex                      # Agent-internal inference loop
        tool.ex                         # Tool behaviour
        tool_router.ex                  # Tool name → executor mapping
        tool_executor.ex                # Tool call execution
        marker_emitter.ex               # SCTE marker interception
        tools/
          bash.ex                       # Shell execution tool
          subagent.ex                   # Sub-agent tool
      conversation.ex                   # Per-conversation supervisor lifecycle
      history.ex                        # Conversation history retrieval
      landscape.ex                      # Cross-conversation summaries
      system_prompt.ex                  # System prompt assembly
      turn_assembly.ex                  # Turn assembly supervisor
      nix_env.ex                        # Nix devShell environment resolution

    context/
      router.ex                         # conversation_id → working directory
      turn_injector.ex                  # Per-turn context injections

    macro/
      definition.ex                     # Macro struct + JSON parser
      engine.ex                         # Trigger evaluation, activation, injection coordination
      executor.ex                       # Body execution (prompt, script, sequence)
      matcher.ex                        # Pattern compilation (literal + regex)
      registry.ex                       # ETS-backed macro loader + indexer
      revision.ex                       # Epoch-end self-modification
      sidecar.ex                        # Async condition evaluation
      state.ex                          # Per-room, per-macro state (persistent + session)
      trigger.ex                        # Trigger evaluation (match, ambient, once, discovery)

    effects.ex                          # Effects supervisor
    effects/
      pass_reactor.ex                   # Post-inference state mutations
      handoff_writer.ex                 # Handoff generation on !clear
      conversation_summarizer.ex        # Periodic cross-conversation summaries
      continuation_dispatcher.ex        # Auto-continue after handoff with continuation

    media.ex                            # Media supervisor
    media/
      transcoder.ex                     # Transcription dispatch
      transcoder/
        transcriber.ex                  # Whisper STT
      take_collector.ex                 # Chunked audio assembly
      output_segmenter.ex               # Output → segments (sentence/paragraph)
      tts/
        cache.ex                        # In-memory TTS segment cache
        warmer.ex                       # Eager TTS synthesis

    transport/
      http.ex                           # Plug router (all HTTP endpoints)
      openai.ex                         # OpenAI-compatible chat completions
      manifest.ex                       # Segment manifest (event-driven)
      segment_registry.ex               # Chunked audio take tracking

    backend/
      llm.ex                            # LLM behaviour
      llm/
        claude_code.ex                  # Claude Code CLI backend
        cc_stream_parser.ex             # CC stdout → events parser
        cc_mcp_server.ex                # MCP tool server for CC markers
        anthropic.ex                    # Anthropic Messages API backend
        ollama.ex                       # Ollama HTTP API backend
      sse.ex                            # SSE stream parser (Anthropic)
      tts.ex                            # TTS behaviour + ExoVoice impl

    store.ex                            # Persistence boundary (GenServer)
    store/
      repo.ex                           # Ecto Repo
      epoch.ex                          # Epoch schema
      message.ex                        # Message schema
      summary.ex                        # Summary schema
```
