# PROJECT.md — Agent Orientation

This file exists so you don't read every file before doing work. Trust it.
If something here contradicts what you see in code, the code wins — but flag
the discrepancy so this file gets updated.

## What This Is

Cranium v2 is an Elixir OTP application that bridges conversational interfaces
(Matrix, voice clients) to LLM inference via the Anthropic API. It replaces
cranium v1 (Go, delegated to Claude Code subprocesses) with direct API control
over context assembly, streaming, and tool execution.

## Build & Test

```bash
mix deps.get
mix test --no-start          # tests don't need the app running
mix compile --warnings-as-errors
iex -S mix                   # dev REPL
```

Postgres: username `"postgres"`, no password. DB `cranium_dev` / `cranium_test`.
Migrations dir exists but is empty — no schemas yet. Ecto Repo is wired but
Store handlers are all stubs returning `:not_found` or `{:ok, []}`.

## Current State (as of 2026-03-05)

**What works:** Compiles clean. 25 tests pass. Terminology rename complete
(room→conversation, session→epoch). All module files exist with correct structure.

**What doesn't work yet:** No real inference. Agent.infer/3 is a stub that returns
immediately. Store has no Ecto schemas — every handler is a stub. Backend.LLM.Anthropic
has the Req call structure but no SSE parsing (does a single POST, not streaming).
No transports. No migrations.

**Unstaged changes:** The terminology rename from the previous session is sitting
in git as unstaged modifications across ~20 files. Commit or stash before branching.

## Architecture in 30 Seconds

Six pipeline stages, each a GenServer. Messages flow left to right:

```
Transport → Ingress → Context → Agent → Egress → Transport
                                  ↕        ↑
                               Effects ← Store
```

- **Ingress** (singleton): normalizes raw input. Steps: Deduplicator → Transcriber → ImageProcessor → CommandDetector
- **Context** (singleton): assembles inference payload. Steps: Router → PromptBuilder → TurnInjector → HistoryManager
- **Agent** (per-epoch): runs LLM inference loop with tool calls. Steps: Harness → ToolRouter → ToolExecutor → MarkerEmitter
- **Egress** (singleton): chunks output, optional TTS. Steps: Chunker → Synthesizer
- **Effects** (supervised Tasks): async handoff/summary generation
- **Store** (singleton): persistence with soft per-conversation locking

**Epoch** is the coordinator — one per conversation, registered via `Cranium.Epoch.Registry`.
Spawned under `Cranium.Epoch.Supervisor` (DynamicSupervisor). Orchestrates the pipeline
for each round but doesn't hold history (that's Store's job).

Supervision tree uses `:rest_for_one` — Store crash restarts everything downstream.

## Key Patterns

### Stage Pattern (all stages look like this)

```elixir
defmodule Cranium.SomeStage do
  use GenServer
  defstruct buffers: %{}

  # Public API — delegates to GenServer
  def process(message, context), do: GenServer.call(__MODULE__, {:process, message, context})

  # Internal — pure pipeline of step modules
  def do_process(message, context) do
    with {:ok, msg} <- Step1.process(message, context),
         {:ok, msg} <- Step2.process(msg, context) do
      Step3.process(msg, context)
    end
  end

  # GenServer callbacks
  def handle_call({:process, msg, ctx}, _from, state), do: {:reply, do_process(msg, ctx), state}

  # Streaming support
  def handle_info({:chunk, stream_id, chunk}, state) do
    buffers = Cranium.Stage.buffer_chunk(state.buffers, stream_id, chunk)
    {:noreply, %{state | buffers: buffers}}
  end
end
```

### Step Pattern (pure functions inside stages)

```elixir
defmodule Cranium.SomeStage.SomeStep do
  @spec process(map(), map()) :: {:ok, map()} | {:error, term()}
  def process(message, context) do
    # Transform message, return {:ok, enriched_message}
    {:ok, Map.put(message, :new_field, computed_value)}
  end
end
```

Steps are pure functions. They take `(message, context)` and return `{:ok, message}`.
No GenServer, no I/O except Store reads (and those are via `Cranium.Store.*` calls).

### Streaming Protocol

```elixir
{:chunk, stream_id, data}     # incremental data
{:stream_end, stream_id}      # stream complete
# Missing (next task): {:stream_start, stream_id, metadata}
```

Stage behaviour provides `buffer_chunk/3` and `flush_buffer/2` helpers.
Stages choose: `{:buffer, state}` (accumulate) or `{:forward, data, state}` (pass through).

### Backend Behaviour

```elixir
# LLM backend sends tagged messages to caller:
{:llm_text, text}              # text chunk
{:llm_tool_use, %{id, name, input}}  # tool call
{:llm_usage, %{input_tokens, output_tokens}}
{:llm_stop, reason}            # "end_turn" | "tool_use" | {:error, ...}
```

Backends configured in `config/config.exs` under `:cranium, :backends`.
Agent resolves its backend via `Application.get_env(:cranium, :backends)[:llm]`.

### Context Map

The `context` map threaded through steps accumulates:
- `:epoch` — epoch state (saturation, last_invoked_at, interrupted_context, etc.)
- `:identity` — base system prompt text
- `:projects_dir` — path to ~/Projects for Router
- `:mode` — `:text` or `:voice`
- `:now` — current time (injectable for testing)
- `:history_window` — message count limit for HistoryManager

### Command Detection

`!`-prefixed messages are intercepted by CommandDetector before reaching inference:
- `!clear` → `{:command, :clear, %{conversation_id: ...}}`
- `!cancel` → `{:command, :cancel, ...}`
- `!usage` → `{:command, :usage, ...}`
- `!new <name>` → `{:command, :new_conversation, %{..., name: ...}}`

Everything else → `{:ok, normalized_message}` and continues through pipeline.

## Terminology

| Use | Don't Use |
|-----|-----------|
| `conversation_id` | `room_id` |
| `Epoch` / `epoch` | `Session` / `session` |
| `ConversationSummarizer` | `RoomSummarizer` |
| `conversation-handoff` | `room-handoff` |
| `cross-conversation-context` | `cross-room-context` |

See README.md glossary for full term definitions.

## Roadmap (Next Steps)

1. **Stream initialization** — add `{:stream_start, stream_id, metadata}` to
   `Cranium.Stage` behaviour and all stage handle_info clauses
2. **Vertical slice** — one real Anthropic API call with SSE streaming through
   Agent → Egress. Prove it works from `iex -S mix`. No transport, no TTS.
3. **Epoch lifecycle** — implement clear/handoff/saturation tracking

## File Reference

You almost certainly don't need to read all of these. Here's what to read
based on what you're doing:

**Changing pipeline flow:** `epoch.ex` (orchestrator), then the relevant stage
**Adding a new step to a stage:** the stage module (e.g., `ingress.ex`), then look at an existing step in its subdirectory
**Working on streaming:** `stage.ex` (behaviour + helpers), then `egress.ex` (most streaming-aware stage)
**Working on inference:** `agent.ex` + `backend/llm.ex`
**Working on context assembly:** `context.ex` → individual steps in `context/`
**Working on persistence:** `store.ex` (API surface), note schemas don't exist yet
**Working on effects:** `effects.ex` (dispatcher), `effects/handoff_writer.ex` or `effects/conversation_summarizer.ex`

**Files you can skip most of the time:** `ingress/deduplicator.ex`, `ingress/transcriber.ex`,
`ingress/image_processor.ex`, `egress/chunker.ex`, `egress/synthesizer.ex`,
`backend/stt.ex`, `backend/tts.ex` — these are stubs with minimal or no logic.

## Reference Material

- Pipeline architecture design note: `~/Projects/exocortex/notes/Hearth Pipeline Architecture 2026-03-03.md`
- Cranium v1 source (Go): `~/Projects/cranium/`
- INVARIANTS.md in this repo — architectural contracts, not aspirational
