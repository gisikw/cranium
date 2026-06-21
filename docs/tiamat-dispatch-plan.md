# Tiamat dispatch integration plan

Cranium should route inference through Tiamat by adding a Tiamat-backed inference path while preserving Cranium's ownership of conversation persistence, prompt-layer inputs, and tool execution.

This is the implementation plan for `crn-1fc8`.

## Recommendation

Implement Tiamat first as a `Cranium.Backend.LLM`-shaped adapter, but do not let the adapter hand-roll legacy chat JSON.

Instead:

1. add native transcript metadata to stored messages;
2. add a Tiamat turn request assembler that understands the native contract;
3. wrap that assembler/client behind a backend module so the existing Harness/Agent/tool loop can prove the flow with minimal lifecycle churn.

This keeps the first cut small while leaving an escape hatch: if `normalization_delta` and `transcript_delta` persistence start fighting `PassReactor`, lift Tiamat to a higher turn-dispatch boundary later.

## Current Cranium capability vs Tiamat contract

Tiamat wants native turn messages shaped roughly as:

```json
{
  "id": "uuid",
  "parent_id": "uuid-or-null",
  "created_at": "iso timestamp",
  "role": "user|assistant|tool|system",
  "content": [{ "type": "text|tool_use|tool_result|..." }],
  "provenance": { "origin": "cranium|tiamat", "backend": "...", "provider": "...", "model": "..." }
}
```

Cranium has today:

- `messages.id` as a binary UUID primary key;
- `messages.inserted_at`, usable as `created_at`;
- `messages.role`;
- `messages.content` as JSONB content blocks;
- `messages.origin`;
- `messages.usage`, which sometimes contains model/token data;
- `epochs.id`, `epochs.cc_session_id`, `epochs.profile`, `epochs.turn_count`.

Cranium does not yet have:

- explicit `messages.parent_id` for transcript topology;
- a first-class `messages.provenance` JSONB field or equivalent provider fields;
- `provider_message_id` / `provider_request_id` attribution;
- a clean way for `History.contribute/2` to preserve row ids/timestamps/provenance;
- a current-user-turn UUID before inference, because the current user message is appended to history before it is persisted;
- a persistence seam that applies Tiamat `normalization_delta` before appending `transcript_delta`.

## Important current seams

### History currently strips identity

`Cranium.Inference.History.contribute/2` fetches rows from Store, formats each as only `%{"role" => ..., "content" => ...}`, then appends the current user message.

That is fine for provider chat APIs but insufficient for Tiamat. Tiamat routing should use a native transcript builder that keeps durable row identity.

### Current user message is not durable during request assembly

`TurnAssembler` currently:

1. builds history before persisting the current user message;
2. appends the current user message in-memory;
3. persists the current user message only after history construction;
4. dispatches inference.

For Tiamat, the current user turn should have a stable UUID. Options:

- preallocate and persist the current user message before dispatch, then query/build native history including it;
- or preallocate UUID/timestamp in memory and persist that exact row before/after dispatch.

The first option is simpler and more honest, but it changes the existing “fetch before persist to avoid duplicate current message” shape.

### PassReactor owns assistant persistence

`PassReactor` currently persists final assistant output and intermediate tool-loop messages from Agent return payloads.

A Tiamat adapter can initially map `transcript_delta` into existing Agent events/return data. But once Cranium wants exact transcript rows/provenance from Tiamat, `PassReactor` likely needs to persist native deltas rather than reconstructing them from `output` and `intermediate_messages`.

## v0 implementation path

### Phase 1 — audit and schema

- Audit current row-to-native-message mapping (`crn-1611`).
- Add durable transcript metadata (`crn-321c`): likely `parent_id` and `provenance` JSONB at minimum.
- Decide whether to backfill linear parentage for existing epoch rows or leave nullable and rely on Tiamat normalization initially.

### Phase 2 — native request assembly

- Build a Tiamat turn request assembler (`crn-8c64`) that outputs:
  - `schema: tiamat.turn.request.v1`;
  - `request_id`;
  - `session_key` derived from Cranium conversation/epoch identity;
  - `router_profile` from Cranium profile config;
  - `system_prompt.pre/post` as backend-neutral prompt fragments;
  - native transcript `messages` with durable ids/timestamps/provenance;
  - `tools` from `ToolRouter`, unless tools are disabled.

Prompt layers must remain request metadata. Do not inject them into transcript messages.

### Phase 3 — backend-shaped Tiamat adapter

- Add config support for `backend: tiamat` and `router_profile` (`crn-a8da`).
- Implement `Cranium.Backend.LLM.Tiamat` (`crn-5818`) over `POST /v1/router/turns` SSE.
- Convert Tiamat `completed` responses into the existing `{:llm_text, ...}` / `{:llm_stop, "end_turn"}` protocol.
- Convert Tiamat `tool_call` responses into existing `{:llm_tool_use, ...}` / `{:llm_stop, "tool_use"}` protocol.
- Convert Tiamat errors into existing backend error stops.
- Ensure cancellation closes the HTTP request so Tiamat can cancel its backend arm.

### Phase 4 — normalization and transcript deltas

- Apply `normalization_delta` before appending `transcript_delta` (`crn-be7e`).
- Preserve Tiamat-generated assistant UUIDs/provenance where possible.
- Ensure tool-use IDs from Tiamat survive through Cranium tool execution and subsequent tool-result history (`crn-74f3`).

### Phase 5 — tests and smoke

- Unit tests for request assembly.
- Fake Tiamat SSE backend tests for completed/tool_call/error/cancel.
- Store tests for normalization application.
- Optional live smoke against local Tiamat (`crn-319f`).

## Open design decisions

### Backend adapter vs higher-level dispatcher

Backend adapter is recommended for v0 because it minimizes lifecycle changes and reuses the existing Agent tool loop.

Lift Tiamat above Agent/Harness later if either becomes true:

- `stream_chat(messages, opts)` requires too much hidden Tiamat-specific context in `opts`;
- preserving exact Tiamat transcript rows fights `PassReactor`'s current output/intermediate-message persistence model.

### Current user message identity

Recommended default: preallocate/persist the current user message before Tiamat dispatch, then build native history from Store including that row. This avoids asking Tiamat to normalize a turn Cranium could have identified itself.

Need care to avoid duplicate current messages in non-Tiamat backends; this may require a separate native-history path rather than modifying `History.contribute/2` globally at first.

### Session key

Tiamat's `session_key` should probably be derived from Cranium's epoch/conversation unit of accretion, not from provider/model. A reasonable v0 candidate:

```text
cranium:<conversation_id>:<epoch_id>
```

This keeps Claude Code session/cache affinity stable across Tiamat arm selection while respecting epoch boundaries.

### Prompt layers

Cranium's current assembled system prompt can initially become one `system_prompt.pre` fragment, but the better target is named fragments:

- identity/core prompt;
- tool guidance if enabled;
- room handoff;
- injected/caller final constraints if any.

Tiamat owns arm-specific middle fragments.

## Ticket breakdown

- `crn-1611` — audit current history rows against the native transcript contract.
- `crn-321c` — add durable transcript metadata to messages.
- `crn-be7e` — apply Tiamat normalization deltas to stored rows.
- `crn-8c64` — build Tiamat turn request assembler with prompt pre/post layers.
- `crn-5818` — implement Tiamat backend adapter over `/v1/router/turns` SSE.
- `crn-74f3` — normalize Tiamat transcript deltas into existing Agent tool-loop events.
- `crn-a8da` — add profile/config support for router-profile-based Tiamat dispatch.
- `crn-319f` — add tests and smoke path.

## Non-goals for the first implementation

- Do not remove existing direct Anthropic/OpenAI/Ollama/ClaudeCode backends.
- Do not push provider/model selection into Cranium's normal path.
- Do not inject prompt layers into transcript messages.
- Do not rely on Claude Code durable JSONL files as Cranium correctness state.
- Do not implement Tiamat cache/checkpoint state in Cranium.
