cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at this ticket:

**Title:** "Agent tool routing: implement real tool dispatch in ToolExecutor and ToolRouter registration"

**Key characteristics:**
- Describes specific implementations to build: real tool dispatch in ToolExecutor, ToolRouter registration
- Includes architectural decisions already made: runtime registration via `ToolRouter.register/2`, optional `name/0` callback for tool identification
- Expected output is code changes (these decisions → implementation)

This describes **what to build**, not "is this possible?" or "what's broken?".

```json
{"disposition": "route", "workflow": "task"}
```
