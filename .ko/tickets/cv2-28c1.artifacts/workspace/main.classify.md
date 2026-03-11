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

The ticket describes what needs to be built: wiring epoch state into the pipeline context by (1) tracking `last_invoked_at`, (2) passing `saturation` through, and (3) wiring `interrupted_context` and `resume_breadcrumb`. It provides a clear implementation path with specific fields to add/wire. The expected output is committed code changes.
