## Goal

Add Ecto schemas and migrations for the four Store entities, replace all Store handler stubs with real Ecto queries, and wire message persistence + history loading into Epoch so conversations are multi-turn.

## Context

**Current state** (from PROJECT.md): "Store has no Ecto schemas — every handler is a stub." `Cranium.Store.Repo` exists (Postgres adapter), Ecto and Postgrex are in deps, migration aliases are wired (`mix test` runs `ecto.create --quiet && ecto.migrate --quiet`). The migrations directory (`priv/repo/migrations/`) is empty.

**Store API surface** (from `lib/cranium/store.ex`): Four entity groups — epochs (get/upsert), messages (append/get with limit opt), handoffs (save/get_latest), summaries (save/get_all). All handlers are single-clause stubs returning `:not_found` or `{:ok, []}`.

**Consumers already written** — they just need Store to stop lying:
- `Cranium.Context.HistoryManager` calls `Store.get_messages(conversation_id, limit: n)` and expects `[%{role: role, content: content}]`
- `Cranium.Effects.HandoffWriter` calls `Store.get_messages/2` and `Store.save_handoff/2`
- `TurnInjector` reads epoch state from the context map (not directly from Store), so no change needed there

**Multi-turn gap**: `Epoch.build_context/2` (line 186–198 in `epoch.ex`) hardcodes `messages: [%{role: "user", content: text}]` — it never loads history. This is the vertical-slice bypass. We need to load history from Store here for multi-turn to work without wiring the full Context pipeline.

**Message persistence gap**: After `Cranium.Agent.infer/3` completes, the reply map includes `output: String.t()` and `usage: map()` (lines 159–164 in `agent.ex`). Neither the user message nor the assistant response is currently saved. Epoch's `handle_call({:submit, ...})` (lines 129–151) is where both saves should happen.

**Schema directory**: `lib/cranium/store/schemas/` is referenced in the README project layout but doesn't exist yet.

**Test infrastructure**: `test/support/` exists with `mocks.ex`. No `DataCase` yet. `test_helper.exs` conditionally enables the Ecto sandbox if the Repo is running. The standard Ecto sandbox pattern (DataCase template module) is needed for Store integration tests. Existing tests are all pure-function tests with `async: true` — they're unaffected.

**Invariants to uphold**:
- All DB access through `Cranium.Store` — no direct Repo calls from pipeline stages (INVARIANTS.md)
- Schemas define `@type t` (INVARIANTS.md)
- Migrations are forward-only and idempotent (INVARIANTS.md)
- `async: true` unless sharing mutable state; Ecto sandbox tests run in shared mode or use `start_owner!` (INVARIANTS.md)

## Approach

Create a single migration with all four tables, then create one schema module per entity in `lib/cranium/store/schemas/`. Replace each stub handler in `Store` with an Ecto query. Then update `Epoch.build_context/2` to load history from Store, and update `Epoch.handle_call({:submit, ...})` to save both the user message and the assistant response after inference completes. Finally, add a `DataCase` test support module and a `Store` integration test.

## Tasks

1. **[priv/repo/migrations/20260305000001_create_store_tables.exs]** — Create the migration with four tables:
   - `epochs`: `conversation_id text not null unique`, `saturation float default 0.0`, `turn_count integer default 0`, `last_invoked_at utc_datetime_usec`, timestamps.
   - `messages`: `conversation_id text not null`, `role text not null`, `content text not null`, `input_tokens integer`, `output_tokens integer`, timestamps. Index on `(conversation_id, inserted_at)`.
   - `handoffs`: `conversation_id text not null`, `content text not null`, timestamps. Index on `(conversation_id, inserted_at)`.
   - `summaries`: `conversation_id text not null`, `content text not null`, timestamps. Index on `(conversation_id, inserted_at)`.

   Verify: `mix ecto.migrate` runs cleanly; `mix ecto.reset` round-trips.

2. **[lib/cranium/store/schemas/epoch.ex]** — `Cranium.Store.Schema.Epoch`. Fields: `conversation_id`, `saturation`, `turn_count`, `last_invoked_at`. Define `@type t`. Changeset validates `conversation_id` required.
   Verify: `mix compile --warnings-as-errors` passes.

3. **[lib/cranium/store/schemas/message.ex]** — `Cranium.Store.Schema.Message`. Fields: `conversation_id`, `role`, `content`, `input_tokens`, `output_tokens`. Define `@type t`. Changeset validates `conversation_id`, `role`, `content` required.
   Verify: `mix compile --warnings-as-errors` passes.

4. **[lib/cranium/store/schemas/handoff.ex]** — `Cranium.Store.Schema.Handoff`. Fields: `conversation_id`, `content`. Define `@type t`.
   Verify: `mix compile --warnings-as-errors` passes.

5. **[lib/cranium/store/schemas/summary.ex]** — `Cranium.Store.Schema.Summary`. Fields: `conversation_id`, `content`. Define `@type t`.
   Verify: `mix compile --warnings-as-errors` passes.

6. **[test/support/data_case.ex]** — `CraniumTest.DataCase`, a `ExUnit.CaseTemplate`. The `setup` block calls `Ecto.Adapters.SQL.Sandbox.start_owner!(Cranium.Store.Repo, shared: not tags[:async])` and registers `stop_owner` on exit. Store integration tests `use CraniumTest.DataCase`.
   Verify: `mix compile --warnings-as-errors` passes.

7. **[lib/cranium/store.ex]** — Replace all eight stub handlers with real Ecto queries:
   - `get_epoch/1`: `Repo.get_by(Schema.Epoch, conversation_id: id)`, return `{:ok, epoch}` or `:not_found`.
   - `upsert_epoch/2`: `Repo.insert` with `on_conflict: {:replace_all_except, [:conversation_id, :inserted_at]}, conflict_target: :conversation_id`.
   - `append_message/2`: `Repo.insert(%Schema.Message{...})`, return `:ok`.
   - `get_messages/2`: query `Schema.Message` where `conversation_id`, order by `inserted_at ASC`, limit from opts (default 50). Return `{:ok, [%{role: role, content: content}]}`.
   - `save_handoff/2`: `Repo.insert(%Schema.Handoff{...})`, return `:ok`.
   - `get_latest_handoff/1`: query `Schema.Handoff` where `conversation_id`, order by `inserted_at DESC`, limit 1. Return `{:ok, content}` or `:not_found`.
   - `save_summary/2`: `Repo.insert(%Schema.Summary{...})`, return `:ok`.
   - `get_all_summaries/0`: query all `Schema.Summary`, order by `inserted_at DESC`. Return `{:ok, [%{conversation_id, content}]}`.

   Verify: `mix test` passes (existing tests unaffected since they use Mock backends and don't call Store).

8. **[lib/cranium/epoch.ex — build_context/2]** — Update to load message history from Store before building the messages list. Call `Cranium.Store.get_messages(conversation_id, limit: 50)`, format each as `%{"role" => role, "content" => content}`, append the current user message at the end. This makes inference multi-turn without requiring the full Context pipeline.
   Verify: `iex -S mix` manual test: submit two messages to the same conversation, verify the second call sees the first in its messages list.

9. **[lib/cranium/epoch.ex — handle_call({:submit, ...})]** — After building context and before calling `Agent.infer`, save the user message: `Cranium.Store.append_message(conversation_id, %{role: "user", content: text})`. After `Agent.infer` returns `{:ok, result}`, save the assistant message: `Cranium.Store.append_message(conversation_id, %{role: "assistant", content: result.output, output_tokens: result.usage[:output_tokens]})`. Also call `Cranium.Store.upsert_epoch(conversation_id, %{last_invoked_at: DateTime.utc_now(), turn_count: ...})` to keep epoch state current.
   Verify: `iex -S mix` manual test: after a complete submit, `Cranium.Store.get_messages("test-conv")` returns both messages.

10. **[test/cranium/store_test.exs]** — Integration tests using `CraniumTest.DataCase`. Test each handler:
    - `append_message/get_messages`: insert two messages, verify retrieval order and limit.
    - `upsert_epoch`: insert then upsert, verify only one row exists with updated fields.
    - `save_handoff/get_latest_handoff`: insert two handoffs, verify latest is returned.
    - `save_summary/get_all_summaries`: insert summaries from two conversations, verify all returned.

    Verify: `mix test test/cranium/store_test.exs` passes.

## Open Questions

1. **Content field type**: Messages are stored as `text` (plain string). The Anthropic API sends multi-part content blocks (list of `%{type, text}` or `%{type, source, ...}` for images). When ImageProcessor handles images, does it reduce them to a text reference, or does it produce a multi-part content block that needs to be stored? If images need to survive in history, `content` must be JSONB. For now, the plan assumes text-only storage, which covers the conversational case. This decision constrains image-in-history later.

2. **Tool call/result pairs**: The agent loops through tool calls during inference. Should `messages` store the raw Anthropic API message format (including `tool_use` and `tool_result` blocks) so conversations can be exactly replayed through the API? Or is storing just the assistant's final text output sufficient? Exact replay requires JSONB content and more complex message schema; text-only is simpler but loses tool history. This is deferred — the current plan stores text output only.

3. **Epoch table: one row or many?**: The plan uses upsert (one row per `conversation_id`, representing the current epoch). This means we lose epoch history when `!clear` triggers a new epoch. If we want to track epoch boundaries for analytics or handoff chaining, we'd need a different model (e.g., one row per epoch with a `cleared_at` timestamp). Current plan: one row, upsert — simplest.

4. **`turn_count` in upsert_epoch**: Task 9 says to update `turn_count` but the current value isn't known from the attrs map alone — we'd need to read the existing value and increment. Options: (a) use a SQL increment (`fragment("turn_count + 1")`), (b) read-then-write in the GenServer handler, (c) omit turn_count from the initial implementation. Since the GenServer is the only writer, (b) is safe and simple. The plan should use `get_epoch` → increment → `upsert_epoch`.
