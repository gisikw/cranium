cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
## Summary

All 10 tasks complete. 62 tests, 0 failures.

### Changes by task

1. **`priv/repo/migrations/20260305000001_create_store_tables.exs`** — Created migration for `epochs`, `messages`, `handoffs`, `summaries` tables with appropriate indexes.

2–5. **`lib/cranium/store/schemas/{epoch,message,handoff,summary}.ex`** — Four schema modules with `@type t`, changesets, and required field validation.

6. **`test/support/data_case.ex`** — `CraniumTest.DataCase` with Ecto sandbox setup using `start_owner!`.

7. **`lib/cranium/store.ex`** — Replaced all 8 stub handlers with real Ecto queries. Two deviations from the plan:
   - `on_conflict` list includes `:id` (was missing from plan) — required to prevent upsert from replacing the primary key.
   - `get_all_summaries` orders by `[desc: inserted_at, desc: id]` — secondary sort by `id` for deterministic ordering within the same timestamp.

8. **`lib/cranium/epoch.ex` (`build_context/2`)** — Loads history from `Store.get_messages/2`, formats as string-keyed maps, prepends to the current user message.

9. **`lib/cranium/epoch.ex` (`handle_call({:submit, ...})`)** — Saves user message before inference; saves assistant message and upserts epoch (with `get_epoch` → increment → `upsert_epoch`) after successful inference.

10. **`test/cranium/store_test.exs`** — 8 integration tests covering all Store handlers including limit, ordering, upsert idempotency, and cross-conversation queries.
