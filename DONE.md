# DONE: Echo take_id as correlation_id on transcribed messages

Branch: `take-correlation`
Commit: `7385278d34ae06c3e3b3cd759db321ddf1bc5fc2`
(code + tests only — nothing deployed, no service restart, no migrations;
the dev/test DB used by `mix test` is the only DB touched)

## What changed

One production-code change, one doc line, three new tests:

- `lib/cranium/inference/turn_assembler.ex` — in `do_assemble_and_dispatch/4`
  (step 9, where the persisted user message becomes a room event),
  `Cranium.RoomEvents.message_created/3` now receives `header.take_id` as
  its `correlation_id` argument. For text passes `take_id` is nil, so the
  existing default (`correlation_id: nil`) is preserved — additive only.
- `docs/room-sync-protocol.md` — the `message.created` row in the durable
  event table now documents the take echo.
- `test/cranium/inference/turn_assembler_correlation_test.exs` (new) — two
  integration tests, see Verification.
- `test/cranium/room_sync/event_stream_test.exs` — one new wire-level test.

No serializer fixes were needed: `correlation_id` was already carried
end-to-end once the emit site supplied it (verified, see trace below).
The assistant-side `message.created` (PassReactor) uses the 2-arity call
and stays nil, so only the take-committed user message is tagged.

## Where the take id travels (module path trace)

1. **`Cranium.Transport.HTTP`** — `POST /v1/rooms/:room_id/audio-takes`
   (`do_room_audio_take/2`, and equivalently the legacy audio submit in
   `do_submit_pass/1`) mints `take_id`, returns it to the client in the
   response body, and broadcasts a `PassHeader{take_id: take_id}`
   (pass_id == take_id by convention).
2. **`Cranium.Media.Transcoder`** → broadcasts
   `{:transcription_complete, %Transcription{take_id, seq, text}}` per
   segment.
3. **`Cranium.Media.TakeCollector`** — assembles single/multi-segment
   transcriptions and broadcasts
   `{:take_complete, %TakeComplete{take_id, text}}`.
4. **`Cranium.Inference.TurnAssembler`** — its `take_index` maps take_id →
   pass_id (built from the PassHeader), pairs the TakeComplete with the
   header, and in `do_assemble_and_dispatch/4` persists the user message
   and calls `RoomEvents.message_created(room_id, attrs, header.take_id)`
   ← **the change**.
5. **`Cranium.RoomEvents.message_created/3` → `emit/4`** →
   `Cranium.Store.emit_room_event/4` persists the row
   (`room_events.correlation_id`, already in the schema/changeset) and
   returns the event map (`Store.room_event_to_map/1` includes
   `correlation_id`), which is broadcast as `{:room_event, event}`.
6. **`Cranium.RoomSync.EventStream`** — `send_durable_event/2`
   JSON-encodes the *entire* event map, so `correlation_id` reaches the
   SSE wire on both the live path and the catch-up path
   (`Store.list_room_events/3` uses the same projection). Nothing was
   dropped in a view/serializer.

`specs/room-sync.allium` already specified this intent ("correlation_id
ties events back to the command that caused them"; `SubmitAudioTake`
returns take_id as "a correlation ID for the client to track") — the
emit site was just never wired.

## Verification

Baseline before changes (inside `nix develop`; host Elixir 1.18 is too
old for the project's ~> 1.19 requirement):

- `mix test`: **918 tests, 0 failures**

After changes:

- `mix compile --warnings-as-errors`: clean
- `mix test`: **921 tests, 0 failures** (918 + 3 new)

New tests:

1. `turn_assembler_correlation_test.exs` — "take transcription commits
   with take_id as correlation_id": drives the real chain
   (`transcription_complete` → live TakeCollector → `take_complete` →
   TurnAssembler → mocked LLM turn) and asserts both the live
   `{:room_event, ...}` broadcast and the durable
   `Store.list_room_events/2` row carry `correlation_id == take_id` on
   the user `message.created` event.
2. Same file — "text pass commits with nil correlation_id": the non-take
   path is unchanged (broadcast + durable row both nil).
3. `event_stream_test.exs` — "message.created correlation_id reaches the
   wire": a real SSE client over Bandit receives the event and the
   decoded JSON contains `"correlation_id": "<take_id>"`.

## Note for the Hearth client lane

The field is `correlation_id` on the **event envelope** (top level, not
inside `payload`) of the `message.created` room event, on both the SSE
live stream and catch-up replay. When you open a take
(`POST /v1/rooms/:room_id/audio-takes` → `{"take_id": "...", "stream_id":
"..."}`), the user message committed from that take's transcription
arrives as:

```
id: 143
event: message.created
data: {"event_id":"evt_...","room_id":"cranium","seq":143,
       "type":"message.created","occurred_at":"2026-07-22T...Z",
       "correlation_id":"<the take_id you were given>",
       "payload":{"message_id":"...","role":"user","origin":"hearth",
                  "epoch_id":"...","preview":"[Transcribed from audio]\n...",
                  "message":{ /* TranscriptMessage */ }}}
```

Match `event.correlation_id == take_id` (and `payload.role == "user"`) to
confirm your take committed — no more inferring via the reply stream id,
and it survives room re-attach because the durable event replays with the
same `correlation_id`. All non-take messages (typed text, assistant
replies) carry `correlation_id: null`, and old events are unaffected.
