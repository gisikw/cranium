# Cranium history rows vs Tiamat native transcript contract

Audit for `crn-1611`.

## Tiamat target shape

Tiamat's native turn API expects ordered transcript messages with mechanical identity and provenance when available:

```json
{
  "id": "uuid",
  "parent_id": "uuid-or-null",
  "created_at": "2026-06-21T05:48:00Z",
  "role": "user|assistant|tool|system",
  "content": [
    { "type": "text", "text": "..." },
    { "type": "tool_use", "tool_use_id": "...", "tool_name": "...", "tool_input": {} },
    { "type": "tool_result", "tool_result_for": "...", "tool_output": { "value": "...", "is_error": false } }
  ],
  "provenance": {
    "origin": "cranium|tiamat",
    "backend": "...",
    "provider": "...",
    "model": "...",
    "provider_message_id": "...",
    "provider_request_id": "..."
  }
}
```

Prompt layers are separate request metadata, not transcript rows.

## What Cranium can source today

### Durable message identity

`Cranium.Store.Message` uses:

```elixir
@primary_key {:id, :binary_id, autogenerate: true}
```

So every persisted row already has a UUID-shaped durable message id. This can map directly to Tiamat `message.id`.

Caveat: `History.contribute/2` currently discards this id.

### Created timestamp

`messages` has `timestamps(type: :utc_datetime_usec, updated_at: false)`. `inserted_at` can map to Tiamat `created_at`.

Caveat: `History.contribute/2` currently discards this timestamp.

### Role

`messages.role` is persisted as a string and can map to Tiamat role.

Current observed roles:

- `user`
- `assistant`

Tool results are currently represented as `role: "user"` messages containing `tool_result` content blocks, not `role: "tool"` rows. Tiamat allows native `role: "tool"`, but also explicitly says adapters can lower tool results from native rows. For v0, Cranium can keep historical `role: "user"` tool-result messages and translate them to native Tiamat shape in the assembler.

### Content blocks

`messages.content` is JSONB, typed in Ecto as `{:array, :map}`.

Current content block shapes include:

```elixir
%{"type" => "text", "text" => text}
%{type: "text", text: text}
%{type: "tool_use", id: id, name: name, input: input}
%{type: "tool_result", tool_use_id: id, content: result}
```

The OpenAI Responses translator and Agent tool loop both understand Anthropic-shaped `text`, `tool_use`, and `tool_result` blocks. This is close enough to Tiamat's native ontology, but field names need normalization:

| Cranium content block | Tiamat content block |
| --- | --- |
| `type: "text", text` | `type: "text", text` |
| `type: "tool_use", id, name, input` | `type: "tool_use", tool_use_id, tool_name, tool_input` |
| `type: "tool_result", tool_use_id, content` | `type: "tool_result", tool_result_for, tool_output` |

Cranium should normalize atom and string keys while assembling Tiamat requests.

### Origin

`messages.origin` exists and can populate at least `provenance.origin`.

However, current `origin` usually means transport/caller origin (`maw`, `lair`, `orientation`, etc.) more than model provenance. It should not be treated as backend/provider attribution.

### Usage/model

Assistant rows may have `messages.usage`, and Harness enriches usage with `:model` before persistence.

This can provide partial model attribution for assistant rows:

```elixir
usage[:model] || usage["model"]
```

But it is not enough for full Tiamat provenance because it lacks backend, provider, provider message id, and provider request id.

### Epoch/session context

`epochs.id`, `conversation_id`, `profile`, `cc_session_id`, and `turn_count` exist.

For Tiamat `session_key`, a good v0 source is:

```text
cranium:<conversation_id>:<epoch_id>
```

This is stable across turns in an epoch and independent of selected Tiamat arm.

## What Cranium cannot source today

### Parent topology

There is no `messages.parent_id` column.

Tiamat can fabricate linear parentage for flat transcripts, but Cranium should eventually persist parent IDs so it does not repeatedly ask Tiamat to decorate the same rows.

For existing rows, safe options:

1. leave `parent_id` null initially and let Tiamat return normalization assignments;
2. backfill linear parentage per `(conversation_id, epoch_id)` ordered by `(inserted_at, id)`.

Option 2 matches Cranium's current transcript model. Option 1 is safer if we want Tiamat to be the only fabricator initially.

### Full provenance

No field exists for:

- backend;
- provider;
- model as first-class provenance rather than usage metadata;
- provider_message_id;
- provider_request_id;
- provider/backend response id;
- prompt hash or selected arm diagnostics.

Recommended minimal schema addition: `messages.provenance :jsonb`.

Reason: Tiamat provenance will evolve faster than Cranium schema. A JSONB field lets Cranium preserve provenance without new migrations for every provider-specific attribution field.

### Current user message identity before dispatch

Current `TurnAssembler` deliberately builds history before persisting the current user message:

1. fetch history;
2. append current message in memory;
3. persist current user row;
4. dispatch turn.

That means the current user message sent to a backend does not have its DB UUID in the in-memory `messages` list.

For Tiamat, this is not ideal. The final user turn should have an ID before dispatch.

Recommended v0 Tiamat path: preallocate/persist the current user message before assembling the native Tiamat history, then query/build history including the current row. This avoids duplicate current-message handling and gives Tiamat stable IDs.

Do not globally change `History.contribute/2` until existing backends are checked, because direct backends currently rely on the fetch-before-persist shape to avoid duplicates.

### Exact assistant transcript deltas

Today Agent/Harness/PassReactor persist assistant responses as:

- final `output` string -> one assistant text message;
- `intermediate_messages` -> assistant/tool_result pairs from tool loops;
- `usage` -> only on final assistant message.

If Tiamat returns multiple assistant messages, thinking blocks, provider metadata, or exact message UUIDs, current persistence will partially flatten or reconstruct them.

For v0, the Tiamat backend can map simple text/tool_call responses into the existing Agent protocol. For durable exactness, PassReactor needs a native transcript-delta persistence path.

## Current history-building path

`Cranium.Inference.History.contribute/2`:

```elixir
{:ok, history} = Cranium.Store.get_messages(conversation_id, epoch_id: epoch_id)

history
|> Enum.map(&format_message/1)
|> Enum.concat([format_current(text, attachments)])
```

`format_message/1` returns only:

```elixir
%{"role" => to_string(role), "content" => content}
```

Therefore it loses:

- message id;
- parent id if added later;
- inserted_at;
- origin;
- usage/model;
- any future provenance;
- epoch/conversation context.

Do not build Tiamat requests from `History.contribute/2` as-is.

## Recommended new history API

Add a Store/native transcript function rather than overloading current provider history formatting.

Possible shape:

```elixir
Cranium.Store.get_native_messages(conversation_id, epoch_id: epoch_id)
```

or:

```elixir
Cranium.Inference.NativeHistory.contribute(conversation_id, opts)
```

It should return maps shaped for Cranium's native transcript, not provider messages:

```elixir
%{
  id: message.id,
  parent_id: message.parent_id,
  created_at: DateTime.to_iso8601(message.inserted_at),
  role: normalize_role(message),
  content: normalize_content_blocks(message.content),
  provenance: build_provenance(message)
}
```

This keeps provider-specific `History.contribute/2` stable while Tiamat matures.

## Recommended schema changes

Minimal v0:

```elixir
alter table(:messages) do
  add :parent_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
  add :provenance, :jsonb
end

create index(:messages, [:parent_id])
```

Consider also:

```elixir
add :request_id, :binary_id
add :provider_message_id, :string
add :provider_request_id, :string
```

But these can live in `provenance` initially unless querying by them becomes important.

## Normalization delta implications

Tiamat may return assignments like:

```json
{
  "selector": { "index": 0 },
  "assigned": {
    "id": "...",
    "parent_id": null,
    "created_at": "..."
  }
}
```

Cranium should prefer to avoid ID/timestamp normalization for rows it already owns. It should send ids and created_at for persisted rows.

The main useful normalization from Tiamat will be parentage for legacy/flat rows, unless Cranium precomputes parentage itself.

Applying normalization by index is fragile if request messages include an in-memory current user message. Another reason to persist/preallocate the current user row before dispatch.

## Tool history implications

Cranium tool-use blocks currently use `id/name/input`; tool-result blocks use `tool_use_id/content`.

Tiamat wants stable tool pairing. Cranium already has stable tool_use IDs generated by providers/Tiamat and preserved through tool_result rows.

Important: after Tiamat returns a tool call, Cranium must persist the assistant `tool_use` row before executing/persisting the matching tool_result, so the next Tiamat request can lower structured tool history. Current Agent API path does this only as `intermediate_messages` after the full tool loop, not at the first handoff boundary. That is acceptable within one Agent loop, but exact durable transcript semantics may require earlier persistence or native delta buffering.

## Recommended next implementation order

1. Add native history builder tests using existing schema fields only.
2. Add `parent_id` + `provenance` schema fields.
3. Update Store append/list/get paths to round-trip those fields.
4. Add Tiamat assembler against native history.
5. Only then add the Tiamat backend adapter.

## Acceptance for `crn-1611`

This audit identifies:

- current fields that map directly to Tiamat;
- current fields that are lost by `History.contribute/2`;
- schema gaps around parentage and provenance;
- the current-user UUID issue;
- the PassReactor transcript-delta persistence seam;
- the minimal DB/API changes recommended before building the adapter.
