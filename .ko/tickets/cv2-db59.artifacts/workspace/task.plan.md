cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan updated. The two substantive changes from the ticket answers:

1. **Chunk uploads are multipart form-data** (not raw binary): The `PUT /v1/input/:id/:seq` handler reads `conn.body_params["chunk"]` as a `%Plug.Upload{}` and calls `File.read!` on it — identical to how `/v1/submit` handles audio. No changes needed to `Plug.Parsers` config since `:multipart` is already there.

2. **TTL eviction is in scope**: TakeRegistry gains `opened_at` + `completed_at` timestamp fields on each Take, and a periodic `:cleanup` message that evicts takes past the TTL (configurable via `Application.get_env(:cranium, :take_ttl_ms, 86_400_000)`).

Everything else in the plan stands as-is.
