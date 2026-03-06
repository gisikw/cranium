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

This ticket describes specific code changes to implement: tracking saturation via `upsert_epoch` during inference, with architectural decisions already determined (expose `compute_saturation` as a public function with @doc false, create epoch row on process start in init/1, and read max context token limit from model configuration). The expected output is committed code.
