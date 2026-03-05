cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `.ko/tickets/cv2-3a64.artifacts/plan.md`. Here's a summary:

**Goal**: Ecto schemas + migrations for 4 entities, real Store handlers replacing stubs, multi-turn history loading in Epoch, and message persistence after each round.

**10 ordered tasks:**
1. Migration: `epochs`, `messages`, `handoffs`, `summaries` tables
2-5. Schema modules: `Epoch`, `Message`, `Handoff`, `Summary` (each with `@type t`)
6. `test/support/data_case.ex` — Ecto sandbox test template
7. `store.ex` — replace all 8 stub handlers with real Ecto queries
8. `epoch.ex:build_context` — load history from Store so inference is multi-turn
9. `epoch.ex:handle_call({:submit})` — save user + assistant messages, upsert epoch after each round
10. `test/cranium/store_test.exs` — integration tests using DataCase

**4 open questions flagged** as genuine architectural decisions:
1. Content field as `text` vs JSONB (affects image-in-history capability)
2. Whether to store tool call/result pairs or just final assistant text
3. Epoch table: one row per conversation (upsert) vs one row per epoch lifecycle
4. How to increment `turn_count` safely in the upsert (read-then-write vs SQL fragment)
