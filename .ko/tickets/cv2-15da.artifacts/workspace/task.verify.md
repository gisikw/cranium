warning: Git tree '/home/dev/Projects/cranium-v2' is dirty
cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28

17:14:43.344 [info] Manifest registry started

17:14:43.347 [info] TTS cache started

17:14:43.347 [info] Egress stage started
Running ExUnit with seed: 356520, max_cases: 24

...................................
17:14:43.503 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
..
17:14:43.504 [info] Manifest registry started

17:14:43.504 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
.
17:14:43.504 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
.
17:14:43.505 [info] Manifest registry started
........................
17:14:43.585 [error] TTS failed: :timeout
..
17:14:43.588 [info] Transcribing audio
.
17:14:43.588 [info] Transcribing audio

17:14:43.588 [error] Transcription failed: :timeout
..
17:14:43.592 [info] Store started
.
17:14:43.594 [info] Store started
.
17:14:43.594 [info] Store started
.
17:14:43.595 [info] Store started

17:14:43.596 [info] Epoch started

17:14:43.609 [debug] QUERY OK source="epochs" db=0.5ms queue=2.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-326"]

17:14:43.639 [debug] QUERY OK source="epochs" db=3.9ms queue=0.4ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "test-saturation-326", 0.0, 0, ~U[2026-03-06 17:14:43Z], ~U[2026-03-06 17:14:43Z], "88da0ea3-bffb-444b-9833-1f7aa02a6c0a"]

17:14:43.639 [info] Processing message

17:14:43.641 [debug] QUERY OK source="messages" db=0.2ms queue=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["test-saturation-326", "user", "hello", ~U[2026-03-06 17:14:43.640871Z], "912d465c-e32d-49ea-b925-b1342453e344"]

17:14:43.644 [debug] QUERY OK source="epochs" db=0.3ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-326"]

17:14:43.654 [debug] QUERY OK db=0.4ms queue=0.6ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["test-saturation-326", 50]

17:14:43.656 [info] Agent started

17:14:43.656 [debug] QUERY OK source="epochs" db=0.3ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-326"]

17:14:43.657 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
UPDATE "epochs" SET "status" = $1, "updated_at" = $2 WHERE "id" = $3 ["inferring", ~U[2026-03-06 17:14:43Z], "88da0ea3-bffb-444b-9833-1f7aa02a6c0a"]

17:14:43.657 [debug] Stream started

17:14:43.657 [info] Inference complete

17:14:43.658 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-326"]

17:14:43.658 [debug] QUERY OK source="epochs" db=0.1ms queue=0.1ms
UPDATE "epochs" SET "status" = $1, "saturation" = $2, "turn_count" = $3, "updated_at" = $4 WHERE "id" = $5 ["active", 0.5, 1, ~U[2026-03-06 17:14:43Z], "88da0ea3-bffb-444b-9833-1f7aa02a6c0a"]

17:14:43.658 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-saturation-326"]
.
17:14:43.659 [info] Store started
.
17:14:43.660 [info] Store started

17:14:43.660 [info] Epoch started

17:14:43.662 [debug] QUERY OK source="epochs" db=1.4ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["test-clear-7557"]

17:14:43.662 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "test-clear-7557", 0.0, 0, ~U[2026-03-06 17:14:43Z], ~U[2026-03-06 17:14:43Z], "a1c07463-dc72-490d-b65f-48785ffb1198"]

17:14:43.662 [info] Clearing epoch

17:14:43.663 [info] Generating handoff

17:14:43.665 [info] Generating handoff

17:14:43.667 [debug] QUERY OK db=1.5ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["test-clear-7557", 100]

17:14:43.669 [debug] QUERY OK source="handoffs" db=0.4ms queue=0.3ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["test-clear-7557", "handoff content", ~U[2026-03-06 17:14:43Z], "8d99fd15-04f0-4925-8cee-57d25fd88f83"]

17:14:43.670 [debug] QUERY OK source="handoffs" db=0.2ms queue=0.4ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["test-clear-7557"]
.
17:14:43.670 [info] Store started

17:14:43.673 [debug] QUERY OK source="summaries" db=0.5ms queue=0.9ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-a"]

17:14:43.674 [debug] QUERY OK source="summaries" db=0.2ms queue=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "alpha summary", ~U[2026-03-06 17:14:43Z], ~U[2026-03-06 17:14:43Z], "1d1ea995-3bbe-40e6-a736-e5ba42a46686"]

17:14:44.776 [debug] QUERY OK source="summaries" db=0.7ms queue=0.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-b"]

17:14:44.776 [debug] QUERY OK source="summaries" db=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "bravo summary", ~U[2026-03-06 17:14:44Z], ~U[2026-03-06 17:14:44Z], "50bebd2b-7210-46ba-a8b6-f148b3f20ab7"]

17:14:44.777 [debug] QUERY OK source="summaries" db=0.2ms queue=0.4ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:14:44.778 [info] Store started

17:14:44.779 [debug] QUERY OK source="messages" db=0.6ms queue=0.6ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-a", "user", "alpha", ~U[2026-03-06 17:14:44.778361Z], "33af7804-ab90-44be-a726-a2cb55e8feef"]

17:14:44.780 [debug] QUERY OK source="messages" db=0.3ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-b", "user", "bravo", ~U[2026-03-06 17:14:44.779907Z], "b5c0b149-4037-4f28-a1a6-3cb785646ee7"]

17:14:44.781 [debug] QUERY OK source="messages" db=0.4ms queue=0.8ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-a"]

17:14:44.782 [debug] QUERY OK source="messages" db=0.3ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-b"]
.
17:14:44.782 [info] Store started

17:14:44.784 [debug] QUERY OK source="handoffs" db=1.4ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["nonexistent"]
.
17:14:44.785 [info] Store started

17:14:44.786 [debug] QUERY OK source="handoffs" db=0.6ms queue=0.4ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "first handoff", ~U[2026-03-06 17:14:44Z], "a6074fd2-a9ea-4ecc-a9e9-4fa72a4a9479"]

17:14:44.786 [debug] QUERY OK source="handoffs" db=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "second handoff", ~U[2026-03-06 17:14:44Z], "dd4e0f41-2fba-4237-b11f-73766fbf1add"]

17:14:44.787 [debug] QUERY OK source="handoffs" db=0.1ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-1", "third handoff", ~U[2026-03-06 17:14:44Z], "fb2cb144-48c1-4da9-b3e2-31ad8d08b5db"]

17:14:44.788 [debug] QUERY OK source="handoffs" db=1.0ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-1"]
.
17:14:44.789 [info] Store started

17:14:44.790 [debug] QUERY OK source="messages" db=0.4ms queue=0.4ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "hello", ~U[2026-03-06 17:14:44.789323Z], "465a3687-9ff8-4ddc-b488-30327d9b372d"]

17:14:44.790 [debug] QUERY OK source="messages" db=0.2ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "assistant", "hi there", ~U[2026-03-06 17:14:44.790447Z], "cf3a74e2-7fd5-4f14-9d27-1fafd90b8872"]

17:14:44.791 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "user", "how are you?", ~U[2026-03-06 17:14:44.790834Z], "9897eabf-a345-459f-af30-76b528fde085"]

17:14:44.792 [debug] QUERY OK source="messages" db=1.1ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["conv-1"]
.
17:14:44.792 [info] Store started

17:14:44.794 [debug] QUERY OK source="messages" db=0.4ms queue=0.4ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 1", ~U[2026-03-06 17:14:44.793012Z], "a19cb56b-c14a-4fd3-a16a-e7ed92dc6e09"]

17:14:44.794 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 2", ~U[2026-03-06 17:14:44.794201Z], "bb77f046-e0d4-45c1-bfb9-3860adbd0a6c"]

17:14:44.794 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 3", ~U[2026-03-06 17:14:44.794565Z], "a5993cc7-b5df-42f7-adc3-f2a9faaa4e43"]

17:14:44.795 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 4", ~U[2026-03-06 17:14:44.794895Z], "54dddc15-48f5-4e85-89d1-b5698965703a"]

17:14:44.795 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 5", ~U[2026-03-06 17:14:44.795194Z], "6cda1d72-5f6a-45da-8116-6de3cebc370e"]

17:14:44.795 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 6", ~U[2026-03-06 17:14:44.795477Z], "57f8a521-9f18-4910-b152-2170b914e282"]

17:14:44.796 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 7", ~U[2026-03-06 17:14:44.795794Z], "872de65f-0ef2-4704-b14e-3b8a6621602a"]

17:14:44.796 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 8", ~U[2026-03-06 17:14:44.796089Z], "377261c0-a4e0-42ec-b086-706ce7632a2a"]

17:14:44.796 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 9", ~U[2026-03-06 17:14:44.796344Z], "df51b426-2d79-4bbe-ab1a-af871d3e083f"]

17:14:44.796 [debug] QUERY OK source="messages" db=0.1ms
INSERT INTO "messages" ("conversation_id","role","content","inserted_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-2", "user", "msg 10", ~U[2026-03-06 17:14:44.796571Z], "2a6ae45a-1192-4228-bc98-9f5a024d61ea"]

17:14:44.798 [debug] QUERY OK db=1.1ms
SELECT s0."id", s0."conversation_id", s0."role", s0."content", s0."inserted_at" FROM (SELECT sm0."id" AS "id", sm0."conversation_id" AS "conversation_id", sm0."role" AS "role", sm0."content" AS "content", sm0."inserted_at" AS "inserted_at" FROM "messages" AS sm0 WHERE (sm0."conversation_id" = $1) ORDER BY sm0."inserted_at" DESC, sm0."id" DESC LIMIT $2) AS s0 ORDER BY s0."inserted_at", s0."id" ["conv-2", 3]
.
17:14:44.798 [info] Store started

17:14:44.800 [debug] QUERY OK source="epochs" db=1.6ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:14:44.801 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7) ["active", "conv-1", 0.0, 0, ~U[2026-03-06 17:14:44Z], ~U[2026-03-06 17:14:44Z], "140ab4f9-a5a2-4bdb-b254-a648d4ff66f9"]

17:14:44.801 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:14:44.801 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:14:44.802 [debug] QUERY OK source="epochs" db=0.2ms queue=0.2ms
UPDATE "epochs" SET "saturation" = $1, "turn_count" = $2, "updated_at" = $3 WHERE "id" = $4 [0.3, 5, ~U[2026-03-06 17:14:44Z], "140ab4f9-a5a2-4bdb-b254-a648d4ff66f9"]

17:14:44.803 [debug] QUERY OK source="epochs" db=0.2ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
17:14:44.803 [info] Store started

17:14:44.804 [debug] QUERY OK source="summaries" db=1.0ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:14:44.805 [info] Store started

17:14:44.806 [debug] QUERY OK source="summaries" db=1.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

17:14:44.807 [debug] QUERY OK source="summaries" db=0.1ms queue=0.2ms
INSERT INTO "summaries" ("conversation_id","content","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5) ["conv-1", "first version", ~U[2026-03-06 17:14:44Z], ~U[2026-03-06 17:14:44Z], "f771ff5c-4650-44cf-afc0-094dba6fb570"]

17:14:44.807 [debug] QUERY OK source="summaries" db=0.1ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 WHERE (s0."conversation_id" = $1) ["conv-1"]

17:14:44.808 [debug] QUERY OK source="summaries" db=0.2ms queue=0.1ms
UPDATE "summaries" SET "content" = $1, "updated_at" = $2 WHERE "id" = $3 ["second version", ~U[2026-03-06 17:14:44Z], "f771ff5c-4650-44cf-afc0-094dba6fb570"]

17:14:44.808 [debug] QUERY OK source="summaries" db=0.4ms
SELECT s0."id", s0."conversation_id", s0."content", s0."inserted_at", s0."updated_at" FROM "summaries" AS s0 ORDER BY s0."updated_at" DESC []
.
17:14:44.809 [info] Store started

17:14:44.811 [debug] QUERY OK source="messages" db=1.7ms
SELECT m0."id", m0."conversation_id", m0."role", m0."content", m0."inserted_at" FROM "messages" AS m0 WHERE (m0."conversation_id" = $1) ORDER BY m0."inserted_at", m0."id" ["nonexistent"]
.
17:14:44.811 [info] Store started

17:14:44.813 [debug] QUERY OK source="epochs" db=1.9ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["nonexistent"]
.
17:14:44.814 [info] Store started

17:14:44.815 [debug] QUERY OK source="handoffs" db=0.3ms queue=0.6ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-a", "alpha handoff", ~U[2026-03-06 17:14:44Z], "d011c35a-9046-4f8e-8f13-526b5363ec94"]

17:14:44.816 [debug] QUERY OK source="handoffs" db=0.2ms
INSERT INTO "handoffs" ("conversation_id","content","inserted_at","id") VALUES ($1,$2,$3,$4) ["conv-b", "bravo handoff", ~U[2026-03-06 17:14:44Z], "59198f3b-5d44-4c0b-a115-553c93115f6c"]

17:14:44.817 [debug] QUERY OK source="handoffs" db=0.9ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-a"]

17:14:44.817 [debug] QUERY OK source="handoffs" db=0.1ms
SELECT h0."id", h0."conversation_id", h0."content", h0."inserted_at" FROM "handoffs" AS h0 WHERE (h0."conversation_id" = $1) ORDER BY h0."inserted_at" DESC LIMIT 1 ["conv-b"]
.
17:14:44.817 [info] Store started

17:14:44.819 [debug] QUERY OK source="epochs" db=1.0ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]

17:14:44.819 [debug] QUERY OK source="epochs" db=0.1ms queue=0.2ms
INSERT INTO "epochs" ("status","conversation_id","saturation","turn_count","system_prompt","inserted_at","updated_at","id") VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ["active", "conv-1", 0.0, 0, "You are helpful.", ~U[2026-03-06 17:14:44Z], ~U[2026-03-06 17:14:44Z], "9bbf8a9f-5d34-4f23-bb0c-a34755143602"]

17:14:44.820 [debug] QUERY OK source="epochs" db=0.1ms
SELECT e0."id", e0."conversation_id", e0."status", e0."system_prompt", e0."turn_count", e0."saturation", e0."inserted_at", e0."updated_at" FROM "epochs" AS e0 WHERE (e0."conversation_id" = $1) ["conv-1"]
.
17:14:44.820 [info] TTS cache started
.
17:14:44.820 [info] TTS cache started
.
17:14:44.882 [info] TTS cache started
.
17:14:44.883 [info] TTS cache started
.
17:14:44.883 [info] TTS cache started
.
17:14:44.883 [info] TTS cache started
.
17:14:44.883 [info] TTS cache started
.
17:14:44.883 [info] TTS cache started

17:14:44.934 [info] TTS cache: evicted 1 unconsumed entries for stream s1
.
17:14:44.985 [debug] Stream started

17:14:44.985 [debug] Segment emitted

17:14:44.986 [debug] Segment emitted

17:14:44.986 [debug] Segment emitted
.
17:14:45.036 [debug] Stream started

17:14:45.036 [debug] Segment emitted

17:14:45.036 [debug] Segment emitted
.
17:14:45.088 [debug] Stream started

17:14:45.088 [debug] Segment emitted
.
17:14:45.139 [debug] Stream started

17:14:45.139 [debug] Segment emitted

17:14:45.139 [debug] Segment emitted
.
17:14:45.190 [debug] Stream started

17:14:45.190 [debug] Segment emitted

17:14:45.190 [debug] Segment emitted
.
17:14:45.241 [debug] Stream started

17:14:45.241 [debug] Segment emitted

17:14:45.241 [debug] Segment emitted
.
17:14:45.292 [debug] Stream started

17:14:45.292 [debug] Segment emitted

17:14:45.313 [debug] Segment emitted
.
17:14:45.334 [debug] Stream started

17:14:45.334 [debug] Segment emitted

17:14:45.334 [debug] Segment emitted
...
17:14:45.392 [debug] Manifest poll: stream=http-shape-text-520 status=streaming segments=1
.
17:14:45.392 [error] TTS synthesis failed: stream=http-audio-fail-450 segment=0 reason=:connection_refused
.
17:14:45.393 [debug] Manifest poll: stream=http-test-1035 status=streaming segments=1
.
17:14:45.393 [debug] Manifest poll: stream=nonexistent not_found
....
17:14:45.393 [debug] Manifest poll: stream=http-shape-both-584 status=complete segments=3
..
Finished in 2.0 seconds (0.2s async, 1.8s sync)
126 tests, 0 failures
