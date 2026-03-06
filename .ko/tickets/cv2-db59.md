---
id: cv2-db59
status: closed
deps: []
created: 2026-03-06T16:59:35Z
type: task
priority: 2
---
# Input protocol: chunked audio upload with take/seal/backfill (start → chunk → done → backfill missing)

## Notes

**2026-03-06 17:23:28 UTC:** Question: Should the TakeRegistry implement TTL-based cleanup for completed takes?
Answer: Add TTL eviction now
Implement automatic cleanup with configurable TTL (e.g., 24h after completion)

**2026-03-06 17:23:28 UTC:** Question: What Content-Type format do chunk uploads use?
Answer: Multipart form data
Client sends chunks wrapped in multipart/form-data with form fields

**2026-03-06 17:23:28 UTC:** Question: How should the server determine the expected range of chunks in a take?
Answer: Client sends `last_seq` in body (Recommended)
Client includes highest sequence number in /done request; server uses it to compute missing range

**2026-03-06 17:33:51 UTC:** ko: FAIL at node 'verify' — node 'verify' failed after 3 attempts: command failed: exit status 2
warning: Git tree '/home/dev/Projects/cranium-v2' is dirty
cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28

17:33:49.717 [info] Manifest registry started

17:33:49.719 [info] TTS cache started

17:33:49.720 [info] TakeRegistry started (ttl=86400000ms)

17:33:49.720 [info] Egress stage started
Running ExUnit with seed: 730751, max_cases: 24

..............
17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)

17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)

17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)

17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)
....
17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)
.
17:33:49.871 [info] TakeRegistry started (ttl=86400000ms)
.
17:33:49.872 [info] TakeRegistry started (ttl=86400000ms)
.
17:33:49.872 [info] TakeRegistry started (ttl=86400000ms)
.
17:33:49.872 [info] TakeRegistry started (ttl=86400000ms)
.
17:33:49.872 [info] TakeRegistry started (ttl=86400000ms)
.............
17:33:49.896 [info] Manifest registry started
.
17:33:49.896 [info] Manifest registry started
.
17:33:49.896 [info] Manifest registry started
.
17:33:49.896 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
.
17:33:49.897 [info] Manifest registry started
..............................
17:33:50.001 [error] TTS failed: :timeout
....
17:33:50.003 [info] Transcribing audio

17:33:50.003 [error] Transcription failed: :timeout
..
17:33:50.003 [info] Transcribing audio
..
17:33:50.007 [info] Store started
.
17:33:50.009 [info] Store started
.
17:33:50.010 [info] Store started

17:33:50.011 [info] Epoch started

17:33:50.025 [debug] QUERY OK source="epochs" db=0.5ms queue=2.5ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-1220"]

17:33:50.053 [debug] QUERY OK source="epochs" db=3.6ms queue=0.4ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "test-saturation-1220", 0.0, 0, ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "df711009-3502-4d1b-abe2-2a1a7dcd86ab"]

17:33:50.053 [info] Processing message

17:33:50.055 [debug] QUERY OK source="messages" db=0.3ms queue=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["test-saturation-1220", "user", "hello", ~U[2026-03-06 17:33:50.054695Z], "f0bfedc4-f821-49c5-ad12-ec634cda77eb"]

17:33:50.058 [debug] QUERY OK source="epochs" db=0.3ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-1220"]

17:33:50.067 [debug] QUERY OK db=0.4ms queue=0.6ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["test-saturation-1220", 50]

17:33:50.069 [info] Agent started

17:33:50.069 [debug] QUERY OK source="epochs" db=0.3ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-1220"]

17:33:50.070 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
UPDATE "epochs" SET "status" = $1, "updated_at" = $2 WHERE "id" = $3 ["inferring", ~U[2026-03-06 17:33:50Z], "df711009-3502-4d1b-abe2-2a1a7dcd86ab"]

17:33:50.070 [debug] Stream started

17:33:50.070 [info] Inference complete

17:33:50.070 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-1220"]

17:33:50.071 [debug] QUERY OK source="epochs" db=0.1ms queue=0.1ms
UPDATE "epochs" SET "status" = $1, "saturation" = $2, "turn_count" = $3, "updated_at" = $4 WHERE "id" = $5 ["active", 0.5, 1, ~U[2026-03-06 17:33:50Z], "df711009-3502-4d1b-abe2-2a1a7dcd86ab"]

17:33:50.071 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-1220"]
.
17:33:50.072 [info] Store started
.
17:33:50.072 [info] Store started

17:33:50.072 [info] Epoch started

17:33:50.074 [debug] QUERY OK source="epochs" db=1.3ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-clear-6851"]

17:33:50.075 [debug] QUERY OK source="epochs" db=0.2ms queue=0.3ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "test-clear-6851", 0.0, 0, ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "da1f6aa8-b8a1-43ec-b045-ee9a70696eec"]

17:33:50.075 [info] Clearing epoch

17:33:50.076 [info] Generating handoff

17:33:50.077 [info] Generating handoff

17:33:50.079 [debug] QUERY OK db=1.1ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["test-clear-6851", 100]

17:33:50.081 [debug] QUERY OK source="handoffs" db=0.2ms queue=0.3ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["test-clear-6851", "handoff content", ~U[2026-03-06 17:33:50Z], "4dd6f5a0-1d7d-4d21-a737-06856bbdbdfc"]

17:33:50.081 [debug] QUERY OK source="handoffs" db=0.3ms queue=0.3ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["test-clear-6851"]
.
17:33:50.082 [info] Store started
.
17:33:50.083 [debug] Stream started

17:33:50.083 [debug] Segment emitted

17:33:50.083 [debug] Segment emitted
.
17:33:50.134 [debug] Stream started

17:33:50.134 [debug] Segment emitted

17:33:50.134 [debug] Segment emitted
.
17:33:50.185 [debug] Stream started

17:33:50.185 [debug] Segment emitted

17:33:50.185 [debug] Segment emitted
.
17:33:50.236 [debug] Stream started

17:33:50.236 [debug] Segment emitted

17:33:50.236 [debug] Segment emitted
.
17:33:50.287 [debug] Stream started

17:33:50.287 [debug] Segment emitted

17:33:50.287 [debug] Segment emitted
.
17:33:50.337 [debug] Stream started

17:33:50.338 [debug] Segment emitted
.
17:33:50.389 [debug] Stream started

17:33:50.389 [debug] Segment emitted

17:33:50.409 [debug] Segment emitted
.
17:33:50.431 [debug] Stream started

17:33:50.431 [debug] Segment emitted

17:33:50.431 [debug] Segment emitted

17:33:50.431 [debug] Segment emitted
.
17:33:50.482 [info] TTS cache started
.
17:33:50.483 [info] TTS cache started
.
17:33:50.483 [info] TTS cache started

17:33:50.534 [info] TTS cache: evicted 1 unconsumed entries for stream s1
.
17:33:50.585 [info] TTS cache started
.
17:33:50.647 [info] TTS cache started
.
17:33:50.647 [info] TTS cache started
.
17:33:50.647 [info] TTS cache started
.
17:33:50.647 [info] TTS cache started
.
17:33:50.648 [info] Store started

17:33:50.653 [debug] QUERY OK source="summaries" db=1.0ms queue=1.2ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

17:33:50.653 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "first version", ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "40d138e1-677b-4ffd-a120-800c6666f543"]

17:33:50.654 [debug] QUERY OK source="summaries" db=0.2ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

17:33:50.655 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
UPDATE "summaries" SET "content" = $1, "updated_at" = $2 WHERE "id" = $3 ["second version", ~U[2026-03-06 17:33:50Z], "40d138e1-677b-4ffd-a120-800c6666f543"]

17:33:50.655 [debug] QUERY OK source="summaries" db=0.2ms queue=0.3ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:33:50.656 [info] Store started

17:33:50.657 [debug] QUERY OK source="handoffs" db=0.4ms queue=0.4ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-a", "alpha handoff", ~U[2026-03-06 17:33:50Z], "844cc3ec-a244-4e13-a76c-3b424dd3bed4"]

17:33:50.657 [debug] QUERY OK source="handoffs" db=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-b", "bravo handoff", ~U[2026-03-06 17:33:50Z], "3191e25b-8497-4a78-ab30-3cf7b4dedecf"]

17:33:50.659 [debug] QUERY OK source="handoffs" db=1.1ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-a"]

17:33:50.659 [debug] QUERY OK source="handoffs" db=0.2ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-b"]
.
17:33:50.659 [info] Store started

17:33:50.660 [debug] QUERY OK source="messages" db=0.4ms queue=0.4ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 1", ~U[2026-03-06 17:33:50.660002Z], "16d32fa0-961f-411a-86ff-97a6cc54ff06"]

17:33:50.661 [debug] QUERY OK source="messages" db=0.2ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 2", ~U[2026-03-06 17:33:50.661094Z], "ca4b2bed-044e-4b86-ad31-7323b0a4d24d"]

17:33:50.661 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 3", ~U[2026-03-06 17:33:50.661566Z], "33823d27-82bd-4248-9570-5b86de287e49"]

17:33:50.662 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 4", ~U[2026-03-06 17:33:50.661904Z], "3874aeb8-7dd3-4585-97d0-6d12a67a20ca"]

17:33:50.662 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 5", ~U[2026-03-06 17:33:50.662138Z], "df4c9076-46a3-4ad4-8a40-aeb778000784"]

17:33:50.662 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 6", ~U[2026-03-06 17:33:50.662376Z], "5b46e73e-2c99-4de2-a2a1-3e7812b5b86c"]

17:33:50.662 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 7", ~U[2026-03-06 17:33:50.662637Z], "3ff6bd13-7149-4412-a083-4341ca403605"]

17:33:50.663 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 8", ~U[2026-03-06 17:33:50.662856Z], "44babe17-ba5d-4f2d-8f37-78f6f5b46913"]

17:33:50.663 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 9", ~U[2026-03-06 17:33:50.663177Z], "01268d1c-8aca-4ba9-a814-6a501348d15e"]

17:33:50.663 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 10", ~U[2026-03-06 17:33:50.663376Z], "7f68d760-a513-447b-a285-2b1413a17ce2"]

17:33:50.664 [debug] QUERY OK db=1.2ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["conv-2", 3]
.
17:33:50.665 [info] Store started

17:33:50.667 [debug] QUERY OK source="messages" db=0.5ms queue=0.9ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["nonexistent"]
.
17:33:50.667 [info] Store started

17:33:50.669 [debug] QUERY OK source="epochs" db=1.9ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:33:50.670 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","system_prompt","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ["active", "conv-1", 0.0, 0, "You are helpful.", ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "110792db-0060-40bc-afff-c69aaeabe165"]

17:33:50.671 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
17:33:50.671 [info] Store started

17:33:50.672 [debug] QUERY OK source="handoffs" db=0.3ms queue=0.4ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "first handoff", ~U[2026-03-06 17:33:50Z], "1407c411-fc5d-4e69-b187-b861450b144a"]

17:33:50.673 [debug] QUERY OK source="handoffs" db=0.1ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "second handoff", ~U[2026-03-06 17:33:50Z], "247cdfa9-905e-4c86-a8e6-e4d0fe80773d"]

17:33:50.673 [debug] QUERY OK source="handoffs" db=0.1ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "third handoff", ~U[2026-03-06 17:33:50Z], "36f6085d-8bd4-4b60-a30e-ecdcd01dac5c"]

17:33:50.674 [debug] QUERY OK source="handoffs" db=0.9ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-1"]

17:33:50.675 [info] Store started

17:33:50.676 [debug] QUERY OK source="handoffs" db=1.2ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["nonexistent"]

17:33:50.677 [info] Store started

17:33:50.678 [debug] QUERY OK source="epochs" db=1.4ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:33:50.679 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "conv-1", 0.0, 0, ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "ca53c41f-1b9f-445f-be63-465ed24d6c98"]

17:33:50.679 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]


  1) test save_handoff/get_latest_handoff returns the latest handoff when multiple exist (CraniumTest.StoreTest)
     test/cranium/store_test.exs:78
     match (=) failed
     code:  assert {:ok, "third handoff"} = Cranium.Store.get_latest_handoff("conv-1")
     left:  {:ok, "third handoff"}
     right: {:ok, "first handoff"}
     stacktrace:
       test/cranium/store_test.exs:83: (test)

.
17:33:50.680 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:33:50.680 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
UPDATE "epochs" SET "saturation" = $1, "turn_count" = $2, "updated_at" = $3 WHERE "id" = $4 [0.3, 5, ~U[2026-03-06 17:33:50Z], "ca53c41f-1b9f-445f-be63-465ed24d6c98"]

17:33:50.681 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
17:33:50.681 [info] Store started

17:33:50.683 [debug] QUERY OK source="summaries" db=1.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:33:50.683 [info] Store started

17:33:50.684 [debug] QUERY OK source="messages" db=0.3ms queue=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "hello", ~U[2026-03-06 17:33:50.683727Z], "86a9f51c-fc1a-4bb0-9a43-6cb7f01c0641"]

17:33:50.685 [debug] QUERY OK source="messages" db=0.2ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "assistant", "hi there", ~U[2026-03-06 17:33:50.684736Z], "4e2d209b-49c3-4714-95e8-4cf083a8cd3c"]

17:33:50.685 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "how are you?", ~U[2026-03-06 17:33:50.685123Z], "251dd6cf-06b7-45bf-9d8f-88e42f48d0a0"]

17:33:50.686 [debug] QUERY OK source="messages" db=1.1ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-1"]
.
17:33:50.687 [info] Store started

17:33:50.688 [debug] QUERY OK source="summaries" db=1.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-a"]

17:33:50.689 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "alpha summary", ~U[2026-03-06 17:33:50Z], ~U[2026-03-06 17:33:50Z], "5bafe759-262a-4bb5-8af5-3f056e4c1281"]

17:33:51.790 [debug] QUERY OK source="summaries" db=0.5ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-b"]

17:33:51.791 [debug] QUERY OK source="summaries" db=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "bravo summary", ~U[2026-03-06 17:33:51Z], ~U[2026-03-06 17:33:51Z], "675b8220-e5cd-4448-a0f0-b49b9c46a0e9"]

17:33:51.791 [debug] QUERY OK source="summaries" db=0.6ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:33:51.792 [info] Store started

17:33:51.794 [debug] QUERY OK source="epochs" db=1.4ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["nonexistent"]
.
17:33:51.794 [info] Store started

17:33:51.796 [debug] QUERY OK source="messages" db=0.4ms queue=0.4ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "user", "alpha", ~U[2026-03-06 17:33:51.795102Z], "5ff3d8aa-1077-45c4-a255-2ee2d1bf0d8c"]

17:33:51.796 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "user", "bravo", ~U[2026-03-06 17:33:51.796247Z], "b9f123df-ada3-41c0-97df-a75eaf406ab1"]

17:33:51.797 [debug] QUERY OK source="messages" db=1.2ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-a"]

17:33:51.798 [debug] QUERY OK source="messages" db=0.2ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-b"]
.
17:33:51.805 [info] Input start: take=28e00ff4aa0be6bd stream=a5624935cc453795 conversation=conv-input-1
.
17:33:51.805 [debug] Manifest poll: stream=http-shape-both-1098 status=complete segments=3
.
17:33:51.805 [debug] Manifest poll: stream=nonexistent not_found
...
17:33:51.806 [error] TTS synthesis failed: stream=http-audio-fail-1226 segment=0 reason=:connection_refused
.
17:33:51.806 [debug] Manifest poll: stream=http-shape-text-331 status=streaming segments=1
...
17:33:51.806 [debug] Manifest poll: stream=http-test-2372 status=streaming segments=1
........
Finished in 2.0 seconds (0.2s async, 1.8s sync)
142 tests, 1 failure

