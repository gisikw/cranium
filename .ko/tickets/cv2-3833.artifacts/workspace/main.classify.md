cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at the ticket title and description:

**"Agent tool routing: implement real tool dispatch in ToolExecutor and ToolRouter registration"**

This ticket is clearly asking for **code implementation**:
- "implement real tool dispatch" — specific feature to build
- Identifies concrete components to modify (ToolExecutor, ToolRouter)
- No reported errors or unexpected behavior
- Not asking "can we do this?" or "why is this happening?"
- Expected output: working implementation in those components

```json
{"disposition": "route", "workflow": "task"}
```
