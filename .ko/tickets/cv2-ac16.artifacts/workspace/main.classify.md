cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at the ticket: "Epoch lifecycle: wire !clear to trigger handoff generation via Effects"

This describes a specific implementation: connecting the `!clear` trigger to generate handoffs via Effects. It's describing **what to build** rather than reporting something broken or asking for investigation.

**Classification: task**

This is a feature implementation ticket with a clear objective.

```json
{"disposition": "route", "workflow": "task"}
```
