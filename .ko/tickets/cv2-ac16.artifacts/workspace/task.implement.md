cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Done. Summary of changes:

**Task 1 — `lib/cranium/epoch.ex:198-199`**  
Removed the two comment lines (`# TODO:` and the commented-out call) and replaced with the live call `Cranium.Effects.generate_handoff(state.conversation_id)`. Verified clean compile.

**Task 2 — `test/cranium/epoch_test.exs` (new file)**  
Integration test that:
- Uses `CraniumTest.DataCase, async: false` + `set_mox_global` (required so the background HandoffWriter task can call the LLM mock)
- Starts supervised: `Cranium.Store`, `Cranium.Epoch.Registry`, `Cranium.Epoch.Supervisor`, `Cranium.Effects.Supervisor`
- Configures `LLM.Mock` with `expect(:stream_chat, 1, ...)` — the stub captures `self()` (the HandoffWriter task pid) and sends it to the test process, then spawns a stream process that sends `{:llm_text, "handoff content"}` + `{:llm_stop, "end_turn"}` to the HandoffWriter
- Calls `Epoch.clear/1`, waits for the handoff task pid via `assert_receive`, monitors it, waits for `:DOWN` (task complete), then asserts `Store.get_latest_handoff` returns `{:ok, "handoff content"}`

No deviations from the plan.
