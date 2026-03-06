## Goal

Implement the chunked audio input protocol (start → chunk → done → backfill) as three HTTP endpoints backed by a new `TakeRegistry` GenServer.

## Context

The README's "Input Protocol" section is the spec. The client opens a take, streams numbered audio chunks best-effort, seals the take, backfills any gaps, and the server autonomously triggers inference when all chunks are present. The `/start` endpoint pre-allocates a `stream_id` so the client can start polling the manifest before inference completes.

**Existing patterns to follow:**
- `Cranium.Manifest` is the structural model: a GenServer with a `takes` map, `start_link/1` with `name:` opt, isolated per-test via named process.
- `Cranium.Stage.new_stream_id/0` generates 16-char hex IDs.
- HTTP transport uses `Plug.Router`. Raw binary bodies (PUT chunks) pass through `Plug.Parsers` unmodified when Content-Type is `application/octet-stream`; call `Plug.Conn.read_body/2` in the route handler.
- Inference is triggered by spawning a `Task` in the HTTP handler (see existing `/v1/submit` route). Same pattern here.
- STT backend accessed via `Application.get_env(:cranium, :backends)[:stt]` with fallback to `Cranium.Backend.STT.Whisper`.
- Supervision tree in `application.ex` uses `:rest_for_one`. `TakeRegistry` should sit alongside `Manifest` and `TTS.Cache`.
- `test_helper.exs` manually starts singletons for `--no-start` test mode.
- HTTP tests use `Plug.Test.conn/2` → `HTTP.call/2`. Module-level tests against the global singleton (unique IDs per test). Registry unit tests spin up isolated named processes like `ManifestTest` does.

**Key constraint:** Audio chunks arrive numbered from 0. On seal, the server needs to know `last_seq` (the highest sequence number the client sent) to detect trailing lost chunks. This cannot be inferred from received chunks alone — a 4-chunk upload where chunk 3 was lost would look identical to a 3-chunk upload. The `/done` body must include `last_seq`.

## Approach

Add a `Cranium.Input.TakeRegistry` GenServer that tracks open takes, buffers numbered chunks, computes missing sequences on seal, and assembles the final audio binary when complete. Add three Plug routes to the HTTP transport that delegate to the registry; when a take becomes complete (either at seal or after backfill), the HTTP handler spawns a Task to run STT → epoch submit, identical to the existing `/v1/submit` flow.

## Tasks

1. **`lib/cranium/input/take_registry.ex`** — New GenServer.

   State: `%TakeRegistry{takes: %{take_id => %Take{}}}`

   Take struct fields: `take_id`, `stream_id`, `conversation_id`, `disposition`, `chunks` (map of `seq => binary`), `status` (`:open | :sealed | :complete`), `last_seq` (set on seal).

   Public API (all accept an optional `name:` keyword for test isolation):
   - `open(take_id, stream_id, conversation_id, disposition, opts)` → `:ok | {:error, :conflict}`
   - `put_chunk(take_id, seq, data, opts)` → `{:ok, :buffered} | {:ok, :complete, result} | {:error, reason}`
     where `result` is `%{audio: binary, stream_id: ..., conversation_id: ..., disposition: ...}`
   - `seal(take_id, last_seq, opts)` → `{:ok, :complete, result} | {:ok, :incomplete, missing} | {:error, :not_found}`

   Completeness check: `missing = (0..last_seq |> MapSet.new) -- MapSet.new(Map.keys(chunks))`. Audio assembly: sort chunks by seq, concat binaries. A `put_chunk` on a `:sealed` take runs the completeness check after inserting; if no missing, return `:complete`.

   Verify: `mix test test/cranium/input/take_registry_test.exs` passes.

2. **`lib/cranium/application.ex`** — Add `Cranium.Input.TakeRegistry` to the children list, after `Cranium.TTS.Cache` and before the pipeline stages.

   Verify: `mix compile --warnings-as-errors` passes.

3. **`test/test_helper.exs`** — Add `Cranium.Input.TakeRegistry.start_link(name: Cranium.Input.TakeRegistry)` after the existing singleton starts, so HTTP transport tests can use the global registry.

   Verify: `mix test --no-start` continues to pass.

4. **`lib/cranium/transport/http.ex`** — Add three routes and a private `trigger_audio_inference/4` helper.

   **`POST /v1/input/start`**
   - Read `conversation_id`, `disposition` from JSON body (existing `parse_disposition` helper applies).
   - Generate `take_id = Cranium.Stage.new_stream_id()`, `stream_id = Cranium.Stage.new_stream_id()`.
   - Call `TakeRegistry.open(take_id, stream_id, conversation_id, disposition)`.
   - Call `Manifest.init_stream(stream_id, conversation_id, disposition: disposition)`.
   - Return 200 `{"take_id": ..., "stream_id": ...}`.

   **`PUT /v1/input/:id/:seq`**
   - Parse `seq` as integer; reject non-integer with 400.
   - Read raw body with `Plug.Conn.read_body(conn)`.
   - Call `TakeRegistry.put_chunk(id, seq, data)`.
   - On `{:ok, :buffered}`: return 200 `{"status": "buffered"}`.
   - On `{:ok, :complete, result}`: spawn Task → `trigger_audio_inference(result)`, return 200 `{"status": "complete"}`.
   - On `{:error, :not_found}`: return 404.

   **`POST /v1/input/:id/done`**
   - Read `last_seq` from JSON body; reject missing/non-integer with 400.
   - Call `TakeRegistry.seal(id, last_seq)`.
   - On `{:ok, :complete, result}`: spawn Task → `trigger_audio_inference(result)`, return 200 `{"missing": []}`.
   - On `{:ok, :incomplete, missing}`: return 200 `{"missing": missing}`.
   - On `{:error, :not_found}`: return 404.

   **`trigger_audio_inference/1`** (private, called inside Task)
   - Run STT on `result.audio`.
   - On STT success: `Cranium.Epoch.start_or_get(conversation_id)`, build message map (same shape as `/v1/submit`), call `Cranium.Epoch.submit/2`, schedule `TTS.Cache.schedule_cleanup/1`.
   - On STT failure: log error, call `Cranium.Manifest.complete(stream_id)`.

   Verify: `mix test test/cranium/transport/http_test.exs` passes.

5. **`test/cranium/input/take_registry_test.exs`** — Unit tests, `async: true`, spin up isolated named registry per test (like `ManifestTest`).

   Test cases:
   - `open/5` registers a take; second open with same take_id returns `{:error, :conflict}`.
   - `put_chunk/4` in `:open` state returns `{:ok, :buffered}`.
   - `put_chunk/4` for unknown take returns `{:error, :not_found}`.
   - `seal/3` with all chunks present (last_seq 2, received 0,1,2) returns `{:ok, :complete, result}` with audio assembled in seq order.
   - `seal/3` with missing chunks (last_seq 3, received 0,1,3) returns `{:ok, :incomplete, [2]}`.
   - `put_chunk/4` on `:sealed` take that fills last gap returns `{:ok, :complete, result}`.
   - `put_chunk/4` on `:sealed` take that still has remaining gaps returns `{:ok, :buffered}`.
   - `seal/3` on unknown take returns `{:error, :not_found}`.

   Verify: all pass.

6. **`test/cranium/transport/http_test.exs`** — Add a new `describe "input protocol"` block. Use `async: false` (existing module constraint). Mock STT and Epoch to avoid real inference.

   Test cases (endpoint shape only, not inference integration):
   - `POST /v1/input/start` with valid body → 200, JSON contains `take_id` and `stream_id`.
   - `PUT /v1/input/:id/:seq` for valid take with binary body → 200.
   - `PUT /v1/input/:id/:seq` for unknown take → 404.
   - `POST /v1/input/:id/done` when all chunks present → 200, `{"missing": []}`.
   - `POST /v1/input/:id/done` when chunks missing → 200, `{"missing": [...]}`.
   - `POST /v1/input/:id/done` for unknown take → 404.

   Verify: all pass, existing tests still pass.

## Open Questions

1. **`last_seq` in `/done` body (assumption above).** The README says `/done` "seals the take" and returns `{missing: [...]}`, but doesn't specify how the server knows the expected range. The implementation above requires `last_seq` in the body (the highest sequence number the client sent). If the protocol should infer this differently (e.g., the client includes a `count` field, or it's guaranteed no trailing chunks are lost), this changes the seal logic. **Assumption: require `last_seq` integer in `/done` body; return 400 if absent.**

2. **Chunk Content-Type expectation.** The plan assumes clients send `PUT` chunks with `Content-Type: application/octet-stream` (raw binary). If Hearth sends multipart or base64-encoded JSON instead, the `read_body/2` approach needs adjustment. Clarify Hearth's actual upload format.

3. **Take lifetime / cleanup.** Completed and abandoned takes accumulate in TakeRegistry memory. The plan doesn't add TTL eviction. Acceptable for now (takes are small metadata + audio blobs), but should be tracked as follow-up. Manifest has the same gap.
