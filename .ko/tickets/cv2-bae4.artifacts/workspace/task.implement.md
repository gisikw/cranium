cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
## Summary

**Task 1 — `lib/cranium/manifest.ex`**
Created `Cranium.Manifest` GenServer with:
- `defstruct streams: %{}` wrapping the stream map (per INVARIANTS.md: GenServer state must be a struct)
- Five public API functions with typespecs: `init_stream/2`, `add_utterance/3`, `add_cue/4`, `complete/1`, `get/1`
- `handle_call` for all operations; `handle_cast`/`handle_info` not needed (all synchronous queries/mutations)
- JSON serialization: status atoms → strings, segments sorted by index, utterance renditions include `url`+`mime` only (no `duration`), cues include `cue_type`+`data`

**Task 2 — `lib/cranium/application.ex`**
Added `Cranium.Manifest` as a child before the pipeline stages. No ordering dependency on other stages.

**Task 3 — `test/cranium/manifest_test.exs`**
10 tests covering all operations: `init_stream`, `add_utterance`, `add_cue`, ordering, `complete`, `get` (not_found + README shape). Uses `async: false`, `start_supervised!` in setup to isolate each test with a fresh named GenServer instance, and unique `stream_id` per test.

**Deviation from plan**: Added `start_supervised!(Cranium.Manifest)` in test setup (plan didn't mention this explicitly, but it's required to make the named GenServer available when tests run with `--no-start`). This is standard ExUnit practice for named GenServers.
