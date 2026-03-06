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

This ticket describes a feature to build—a chunked audio upload protocol with specific mechanics (take/seal/backfill workflow). The architectural decisions have already been resolved (TTL cleanup strategy, multipart form-data format, chunk range tracking via `last_seq`). The expected output is implemented code, not investigation or diagnosis.
