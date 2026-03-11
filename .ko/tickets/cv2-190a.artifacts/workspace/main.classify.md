cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at this ticket:

**Key indicators:**
- Specifies **what to build**: move handoff storage from a global Store method to an epoch row field
- Describes a clear architectural change: each epoch should preserve its own handoff
- Outlines the implementation: PromptBuilder reads from previous epoch's row instead of latest global handoff
- Not reporting broken behavior; asserting a design decision

This is describing code changes with a clear direction, not investigating a problem or diagnosing a bug.

```json
{"disposition": "route", "workflow": "task"}
```
