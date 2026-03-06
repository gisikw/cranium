warning: Git tree '/home/dev/Projects/cranium-v2' is dirty
cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28

13:18:03.684 [info] Manifest registry started

13:18:03.686 [info] TTS cache started

13:18:03.686 [info] Egress stage started
Running ExUnit with seed: 696017, max_cases: 24

............................
13:18:03.862 [info] Manifest registry started
.
13:18:03.862 [info] Manifest registry started
.
13:18:03.862 [info] Manifest registry started
.
13:18:03.862 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
.
13:18:03.863 [info] Manifest registry started
..
13:18:03.863 [info] Manifest registry started
.......
13:18:03.864 [info] Manifest registry started
.
13:18:03.864 [info] Manifest registry started
.
13:18:03.864 [info] Manifest registry started
....................
13:18:03.926 [error] TTS failed: :timeout
.......
13:18:03.929 [info] Transcribing audio
.
13:18:03.929 [info] Transcribing audio

13:18:03.929 [error] Transcription failed: :timeout
.
13:18:03.929 [info] TTS cache started
.
13:18:03.930 [info] TTS cache started
.
13:18:03.930 [info] TTS cache started

13:18:03.981 [info] TTS cache: evicted 1 unconsumed entries for stream s1
.
13:18:04.031 [info] TTS cache started
.
13:18:04.031 [info] TTS cache started
.
13:18:04.094 [info] TTS cache started
.
13:18:04.094 [info] TTS cache started
.
13:18:04.094 [info] TTS cache started
.
13:18:04.099 [info] Store started

13:18:04.113 [debug] QUERY OK source="summaries" db=0.5ms queue=2.6ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-a"]

13:18:04.137 [debug] QUERY OK source="summaries" db=3.4ms queue=0.3ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "alpha summary", ~U[2026-03-06 13:18:04Z], ~U[2026-03-06 13:18:04Z], "cc087a2d-f3ff-4457-a147-f6653f808ddc"]

13:18:05.239 [debug] QUERY OK source="summaries" db=0.6ms queue=0.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-b"]

13:18:05.240 [debug] QUERY OK source="summaries" db=0.3ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "bravo summary", ~U[2026-03-06 13:18:05Z], ~U[2026-03-06 13:18:05Z], "5f2d5d14-0a8c-45e8-b633-6d27240ab326"]

13:18:05.241 [debug] QUERY OK source="summaries" db=0.3ms queue=0.4ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
13:18:05.242 [info] Store started

13:18:05.249 [debug] QUERY OK source="messages" db=0.6ms queue=1.2ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["nonexistent"]
.
13:18:05.249 [info] Store started

13:18:05.252 [debug] QUERY OK source="handoffs" db=0.4ms queue=0.5ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-a", "alpha handoff", ~U[2026-03-06 13:18:05Z], "b99e8ee5-176e-4dd3-9886-d323a43e6d8a"]

13:18:05.252 [debug] QUERY OK source="handoffs" db=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-b", "bravo handoff", ~U[2026-03-06 13:18:05Z], "6c0c6107-66a3-4eea-a9a9-0f1f27398d12"]

13:18:05.254 [debug] QUERY OK source="handoffs" db=0.4ms queue=0.6ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-a"]

13:18:05.254 [debug] QUERY OK source="handoffs" db=0.2ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-b"]
.
13:18:05.255 [info] Store started

13:18:05.258 [debug] QUERY OK source="epochs" db=0.5ms queue=0.9ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["nonexistent"]
.
13:18:05.258 [info] Store started

13:18:05.260 [debug] QUERY OK source="summaries" db=1.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

13:18:05.260 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "first version", ~U[2026-03-06 13:18:05Z], ~U[2026-03-06 13:18:05Z], "455ac110-f66c-47e4-979e-9507673c528c"]

13:18:05.261 [debug] QUERY OK source="summaries" db=0.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

13:18:05.261 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
UPDATE "summaries" SET "content" = $1, "updated_at" = $2 WHERE "id" = $3 ["second version", ~U[2026-03-06 13:18:05Z], "455ac110-f66c-47e4-979e-9507673c528c"]

13:18:05.262 [debug] QUERY OK source="summaries" db=0.5ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
13:18:05.262 [info] Store started

13:18:05.264 [debug] QUERY OK source="epochs" db=1.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

13:18:05.267 [debug] QUERY OK source="epochs" db=0.1ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","turn_count","saturation","system_prompt","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ["active", "conv-1", 0, 0.0, "You are helpful.", ~U[2026-03-06 13:18:05Z], ~U[2026-03-06 13:18:05Z], "4a9f9b26-ed04-4c03-a97a-e3f5b5b2d02d"]

13:18:05.267 [debug] QUERY OK source="epochs" db=0.4ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
13:18:05.268 [info] Store started

13:18:05.269 [debug] QUERY OK source="epochs" db=1.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

13:18:05.270 [debug] QUERY OK source="epochs" db=0.1ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","turn_count","saturation","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "conv-1", 0, 0.0, ~U[2026-03-06 13:18:05Z], ~U[2026-03-06 13:18:05Z], "06a1bd8b-dea8-43d7-bf1c-244f871e565c"]

13:18:05.270 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

13:18:05.270 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

13:18:05.271 [debug] QUERY OK source="epochs" db=0.2ms queue=0.1ms
UPDATE "epochs" SET "turn_count" = $1, "saturation" = $2, "updated_at" = $3 WHERE "id" = $4 [5, 0.3, ~U[2026-03-06 13:18:05Z], "06a1bd8b-dea8-43d7-bf1c-244f871e565c"]

13:18:05.271 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
13:18:05.272 [info] Store started

13:18:05.273 [debug] QUERY OK source="handoffs" db=0.3ms queue=0.4ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "first handoff", ~U[2026-03-06 13:18:05Z], "e3a79d40-c330-44a2-b3d4-8ac0c76f853f"]

13:18:05.273 [debug] QUERY OK source="handoffs" db=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "second handoff", ~U[2026-03-06 13:18:05Z], "b8536f98-7f31-444e-ae25-2d37f65dca89"]

13:18:05.274 [debug] QUERY OK source="handoffs" db=0.1ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "third handoff", ~U[2026-03-06 13:18:05Z], "222f8ca8-b349-443c-bc9e-0aa3c926067c"]

13:18:05.275 [debug] QUERY OK source="handoffs" db=1.0ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-1"]
.
13:18:05.275 [info] Store started

13:18:05.276 [debug] QUERY OK source="messages" db=0.3ms queue=0.4ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "user", "alpha", ~U[2026-03-06 13:18:05.275740Z], "f3635ed7-7def-476e-bbb7-efc283e6e3e3"]

13:18:05.276 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "user", "bravo", ~U[2026-03-06 13:18:05.276703Z], "a65fe517-4151-4285-a946-caacc6f5c866"]

13:18:05.278 [debug] QUERY OK source="messages" db=1.0ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-a"]

13:18:05.278 [debug] QUERY OK source="messages" db=0.1ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-b"]
.
13:18:05.278 [info] Store started

13:18:05.279 [debug] QUERY OK source="messages" db=0.3ms queue=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "hello", ~U[2026-03-06 13:18:05.279041Z], "2923a36a-988b-4c76-90a1-1085e78f331d"]

13:18:05.280 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "assistant", "hi there", ~U[2026-03-06 13:18:05.279983Z], "fc1819fc-ff49-441b-a234-25a517b40041"]

13:18:05.280 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "how are you?", ~U[2026-03-06 13:18:05.280289Z], "61e88e3d-3529-4af2-86dd-9ed207d659e8"]

13:18:05.281 [debug] QUERY OK source="messages" db=1.0ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-1"]
.
13:18:05.282 [info] Store started

13:18:05.283 [debug] QUERY OK source="messages" db=0.3ms queue=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 1", ~U[2026-03-06 13:18:05.282217Z], "34b28266-7d6e-443e-95f7-1fbafce39dc7"]

13:18:05.283 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 2", ~U[2026-03-06 13:18:05.283152Z], "b87c0b5e-1a7d-4d9e-944f-6428473cce68"]

13:18:05.283 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 3", ~U[2026-03-06 13:18:05.283484Z], "874aa6fc-6d2b-4aaf-82b4-146cea849432"]

13:18:05.284 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 4", ~U[2026-03-06 13:18:05.283837Z], "8ada94bf-d2b8-4488-b554-ffbf8ef8e207"]

13:18:05.284 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 5", ~U[2026-03-06 13:18:05.284138Z], "4934c185-df3a-43d0-b080-4f00fe835dfb"]

13:18:05.284 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 6", ~U[2026-03-06 13:18:05.284416Z], "e8f79b72-c4b8-46cc-b003-937626b246ab"]

13:18:05.284 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 7", ~U[2026-03-06 13:18:05.284704Z], "262de994-06d2-4108-9c53-690b7a074527"]

13:18:05.285 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 8", ~U[2026-03-06 13:18:05.284937Z], "e3fd7ca9-6d45-4257-bc88-bc39d03656f5"]

13:18:05.285 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 9", ~U[2026-03-06 13:18:05.285169Z], "e81db9b6-1668-469e-93b5-c02ad9c9c5ce"]

13:18:05.285 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 10", ~U[2026-03-06 13:18:05.285445Z], "2a8d4dc8-72c3-41f9-b3ac-e20c8554d1e1"]

13:18:05.289 [debug] QUERY OK db=0.4ms queue=0.9ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["conv-2", 3]
.
13:18:05.290 [info] Store started

13:18:05.291 [debug] QUERY OK source="handoffs" db=1.2ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["nonexistent"]
.
13:18:05.292 [info] Store started

13:18:05.293 [debug] QUERY OK source="summaries" db=1.0ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
13:18:05.293 [debug] Stream started

13:18:05.293 [debug] Segment emitted

13:18:05.293 [debug] Segment emitted
.
13:18:05.345 [debug] Stream started

13:18:05.345 [debug] Segment emitted

13:18:05.365 [debug] Segment emitted
.
13:18:05.387 [debug] Stream started

13:18:05.387 [debug] Segment emitted

13:18:05.387 [debug] Segment emitted
.
13:18:05.438 [debug] Stream started

13:18:05.438 [debug] Segment emitted

13:18:05.438 [debug] Segment emitted
.
13:18:05.488 [debug] Stream started

13:18:05.489 [debug] Segment emitted

13:18:05.489 [debug] Segment emitted
.
13:18:05.540 [debug] Stream started

13:18:05.540 [debug] Segment emitted

13:18:05.541 [debug] Segment emitted

13:18:05.541 [debug] Segment emitted
.
13:18:05.591 [debug] Stream started

13:18:05.591 [debug] Segment emitted
.
13:18:05.643 [debug] Stream started

13:18:05.643 [debug] Segment emitted

13:18:05.643 [debug] Segment emitted
.
13:18:05.694 [info] Store started

13:18:05.697 [info] Epoch started

13:18:05.697 [info] Clearing epoch

13:18:05.699 [info] Generating handoff

13:18:05.700 [info] Generating handoff

13:18:05.702 [debug] QUERY OK db=1.3ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["test-clear-2372", 100]

13:18:05.702 [debug] QUERY OK source="handoffs" db=0.2ms queue=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["test-clear-2372", "handoff content", ~U[2026-03-06 13:18:05Z], "a79f79f0-f024-430b-bc3c-2595857f5767"]

13:18:05.703 [debug] QUERY OK source="handoffs" db=0.4ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["test-clear-2372"]
...
13:18:05.711 [debug] Manifest poll: stream=http-shape-both-1030 status=complete segments=3
....
13:18:05.711 [error] TTS synthesis failed: stream=http-audio-fail-2564 segment=0 reason=:connection_refused
..
13:18:05.712 [debug] Manifest poll: stream=http-test-2628 status=streaming segments=1
.
13:18:05.712 [debug] Manifest poll: stream=nonexistent not_found
.
13:18:05.712 [debug] Manifest poll: stream=http-shape-text-515 status=streaming segments=1
.
Finished in 1.9 seconds (0.2s async, 1.7s sync)
121 tests, 0 failures
