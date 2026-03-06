cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Done. 129 tests, 0 failures. Here's what was implemented:

**`lib/cranium/agent/tool.ex`** — New `Cranium.Agent.Tool` behaviour with `execute/2` (required) and `name/0` (optional via `@optional_callbacks`).

**`config/config.exs`** — Added `config :cranium, :tools, []` documenting the key.

**`lib/cranium/agent/tool_router.ex`** — Added `register/2` (backed by `Application.put_env` for test isolation) and replaced the `{:unknown, name}` stub with `find_handler/1` that looks up the app env registry.

**`lib/cranium/agent/tool_executor.ex`** — Changed public signature to `execute(module(), map(), keyword())`, implemented `do_execute` as `module.execute(input, opts)`, logs using `module.name()` if exported, otherwise `inspect(module)`.

**Tests** — 8 new tests covering marker routing, unknown tools, registered tool lookup, successful dispatch, error passthrough, timeout, and truncation.
