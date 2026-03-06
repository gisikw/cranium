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

This ticket describes concrete code changes to implement:
- Implement real tool dispatch in ToolExecutor
- Add ToolRouter.register/2 for dynamic runtime registration
- Add name/0 callback to Tool behaviour for logging

The architectural decisions are already decided (runtime registration, name callback), so this is ready for implementation rather than investigation.
