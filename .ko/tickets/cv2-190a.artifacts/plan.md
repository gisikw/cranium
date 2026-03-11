## Goal
Store handoff text as a field on the epoch row so each cleared epoch retains its own handoff, replacing the global `handoffs` table writes.

## Context

**Current flow:**
- `Epoch.clear/1` marks epoch "cleared", calls `Effects.generate_handoff(conversation_id, epoch_id)`
- `HandoffWriter.generate/2` runs LLM call, writes result via `Store.save_handoff(conversation_id, text)` — inserts a row in the separate `handoffs` table
- On the first turn of a new epoch (`is_fresh: true`), `PromptBuilder.resolve_handoff/1` calls `Store.get_latest_handoff(conversation_id)` — retrieves the newest row from the `handoffs` table globally

**Key structural issue — unique index:** `priv/repo/migrations/20260306000001_create_store_tables.exs` creates a `unique_index(:epochs, [:conversation_id])`. This prevents multiple epoch rows per conversation. The migration must drop this index to allow epoch history to accrue. (Note: `Store.get_epoch` already queries with `order_by: [desc: e.inserted_at], limit: 1`, so the query layer is already epoch-history-ready.)

**Schema:** `lib/cranium/store/epoch.ex` — has fields `id`, `conversation_id`, `status`, `system_prompt`, `turn_count`, `saturation`. Needs `handoff` added.

**Store:** `lib/cranium/store.ex` — `update_epoch/2` uses `Epoch.changeset` for generic attr updates, so adding `handoff` to the schema/changeset is enough. A new `get_previous_epoch_handoff/1` function is needed.

**HandoffWriter:** `lib/cranium/effects/handoff_writer.ex` line 48 — already has `epoch_id` in scope, just calls the wrong store function.

**PromptBuilder:** `lib/cranium/context/prompt_builder.ex` line 54 — calls `Store.get_latest_handoff(cid)`, needs to call new function instead.

**Tests:** `test/cranium/epoch_test.exs` line 88 asserts `Store.get_latest_handoff/1`. `test/cranium/store_test.exs` has a `save_handoff/get_latest_handoff` describe block. Both need updating.

## Approach

Add a `handoff` text column to the `epochs` table (via migration that also drops the conversation_id unique index). Wire `HandoffWriter` to write `handoff` onto the cleared epoch row via `update_epoch`. Add `Store.get_previous_epoch_handoff/1` that queries the most-recently-cleared epoch with a non-null handoff, and update `PromptBuilder` to call it. Remove `save_handoff`/`get_latest_handoff` from Store since they are replaced.

## Tasks

1. **[priv/repo/migrations/TIMESTAMP_add_handoff_to_epochs.exs]** — New migration: `alter table(:epochs)` to add `:handoff, :text` (nullable). Also `drop_if_exists unique_index(:epochs, [:conversation_id])` so multiple epoch rows per conversation are permitted.
   Verify: `mix ecto.migrate` succeeds.

2. **[lib/cranium/store/epoch.ex]** — Add `field :handoff, :string` to the schema. Add `:handoff` to the `cast/2` call in `changeset/2`.
   Verify: Schema compiles, `mix test` passes.

3. **[lib/cranium/store.ex]** — Three changes:
   a. Add `get_previous_epoch_handoff/1` public spec + `GenServer.call` delegation.
   b. Add `handle_call({:get_previous_epoch_handoff, conversation_id}, ...)` handler: query epochs for `conversation_id` where `status = "cleared"` and `handoff IS NOT NULL`, ordered `desc: inserted_at`, limit 1, return `{:ok, epoch.handoff}` or `:not_found`.
   c. Add `:handoff` to `epoch_to_map/1`.
   d. Remove `save_handoff/2`, `get_latest_handoff/1` public functions and their `handle_call` handlers (they are replaced by the epoch-field approach).
   Verify: `mix test` — no references to the removed functions remain.

4. **[lib/cranium/effects/handoff_writer.ex:48]** — Replace `Cranium.Store.save_handoff(conversation_id, text)` with `Cranium.Store.update_epoch(epoch_id, %{handoff: text})`. The `epoch_id` argument is already in scope.
   Verify: `mix test` passes.

5. **[lib/cranium/context/prompt_builder.ex:54]** — In `resolve_handoff/1`, replace `Cranium.Store.get_latest_handoff(cid)` with `Cranium.Store.get_previous_epoch_handoff(cid)`.
   Verify: `mix test` passes.

6. **[test/cranium/store_test.exs]** — Replace the `describe "save_handoff/get_latest_handoff"` block with a `describe "get_previous_epoch_handoff"` block. Tests should: create two epoch rows (one cleared with a handoff, one cleared without), verify the function returns the handoff from the most recently cleared epoch with content; verify `:not_found` when no cleared handoff exists.
   Verify: New tests pass, no regression.

7. **[test/cranium/epoch_test.exs:88]** — Update the `clear/1` test assertion from `Cranium.Store.get_latest_handoff(conversation_id)` to `Cranium.Store.get_previous_epoch_handoff(conversation_id)`.
   Verify: Test passes with new assertion.

## Open Questions

- **Handoffs table retention:** The `handoffs` table becomes unused after this change. Should it be dropped in the same migration, or left for a follow-up cleanup ticket? The safe default is to leave it in place (no data loss risk), but the migration could drop it if historical handoff data is considered expendable.
- **`is_fresh` detection and previous epoch lookup:** `Router` sets `is_fresh: true` when `turn_count == 0`. `PromptBuilder` then looks up the previous epoch's handoff. If an epoch is fresh but there's no cleared predecessor yet (i.e., the very first epoch ever), `get_previous_epoch_handoff` correctly returns `:not_found` — this is the expected path and no special handling is needed.
