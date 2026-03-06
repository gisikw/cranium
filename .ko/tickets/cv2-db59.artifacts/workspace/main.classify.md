cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Looking at the ticket title and description, this is asking for the implementation of a new input protocol feature for chunked audio uploads with a specific workflow (start → chunk → done → backfill).

This is clearly a **task**: it describes *what to build* (a chunked audio upload protocol with take/seal/backfill semantics), not *what's broken*. The expected output is committed code that implements this protocol.

```json
{"disposition": "route", "workflow": "task"}
```
