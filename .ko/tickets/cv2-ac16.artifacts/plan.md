## Goal

Uncomment the `Effects.generate_handoff` call in `Epoch.handle_call(:clear)` so that `!clear` triggers async handoff generation.

## Context

The implementation is already stubbed out. In `lib/cranium/epoch.ex:195-203`, `handle_call(:clear, ...)` has a TODO comment with the call already written:

```
# TODO: Trigger handoff generation via Effects
# Cranium.Effects.generate_handoff(state.conversation_id)
```

`Cranium.Effects.generate_handoff/1` exists in `lib/cranium/effects.ex` and is fully implemented — it spawns a `Task.Supervisor.start_child` under `Cranium.Effects.Supervisor` which calls `Effects.HandoffWriter.generate/1`. The `HandoffWriter` fetches messages from `Store`, calls the configured LLM backend, and stores the result via `Store.save_handoff/2`. The LLM backend is mockable via `Cranium.Backend.LLM.Mock` (already defined in `test/support/mocks.ex`).

`Cranium.Effects.Supervisor` is a `Task.Supervisor` — it must be running for the Task spawn to succeed (it's part of the supervision tree but won't be auto-started in `--no-start` tests).

## Approach

Uncomment the single `Effects.generate_handoff` call in `epoch.ex`. Then add an integration test in a new `test/cranium/epoch_test.exs` that starts the required processes (Registry, DynamicSupervisor, Effects.Supervisor, Store), configures the LLM mock to emit a short response, calls `clear`, and asserts that a handoff was eventually saved in Store.

## Tasks

1. [lib/cranium/epoch.ex:handle_call(:clear)] — Remove the two comment lines (`# TODO:` and the commented-out call) and replace with the live call `Cranium.Effects.generate_handoff(state.conversation_id)`.
   Verify: `mix compile --warnings-as-errors` clean.

2. [test/cranium/epoch_test.exs] — Create a new test file. Tests need `async: false` (shared Store + Registry state). Setup must `start_supervised!` the following: `Cranium.Store`, `{Registry, keys: :unique, name: Cranium.Epoch.Registry}`, `{DynamicSupervisor, name: Cranium.Epoch.Supervisor, strategy: :one_for_one}`, `{Task.Supervisor, name: Cranium.Effects.Supervisor}`. Configure `Cranium.Backend.LLM.Mock` to respond to `stream_chat/2` by spawning a process that sends `{:llm_text, "handoff content"}` then `{:llm_stop, "end_turn"}` to the caller. Test: start epoch, call `Epoch.clear(pid)`, use `assert_receive` or polling to verify `Store.get_latest_handoff(conversation_id)` returns `{:ok, "handoff content"}`.
   Verify: new test passes, `mix test --no-start` still green.

## Open Questions

None. The call was already written and intentionally commented as a TODO. No ambiguity in behavior or structure.
