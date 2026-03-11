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

This ticket describes a specific code change: persist the enriched TurnInjector system-reminders (with time-gap, saturation, interrupted, and resume injections) in stored message history alongside the raw text. It identifies the current implementation (raw text stored, enriched text discarded) and specifies the desired state. The expected output is committed code that modifies the persistence layer.
