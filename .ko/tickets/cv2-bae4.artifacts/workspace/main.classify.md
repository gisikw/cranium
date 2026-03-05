cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
```json
{"disposition": "route", "workflow": "task"}
```

This ticket describes **what to build**: a new GenServer with four specific API methods (`add_utterance`, `add_cue`, `complete`, `get`), defined data structures, and JSON serialization. The design is already decided (documented in README.md), dependencies are clear, and acceptance criteria are testable. The expected output is committed code with tests.
