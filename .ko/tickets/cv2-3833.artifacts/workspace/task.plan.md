cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Done. Here's what was implemented:

**`lib/cranium/agent/tool.ex`** — New `Cranium.Agent.Tool` behaviour with required `execute/2` and optional `name/0` via `@optional_callbacks`.

**`config/config.exs`** — Added `config :cranium, :tools, []` documenting the key.

**`lib/cranium/agent/tool_router.ex`** — Added `register/2` (backed by `Application.put_env`) and replaced the `{:unknown, name}` stub with `find_handler/1` looking up the runtime registry.

**`lib/cranium/agent/tool_executor.ex`** — Changed public signature to `execute(module(), map(), keyword())`, implemented `do_execute` as `module.execute(input, opts)`, logs via `module.name()` if exported, otherwise `inspect(module)`.

**Tests** — 8 new tests: 3 for ToolRouter (marker, unknown, registered), 5 for ToolExecutor (ok dispatch, error passthrough, timeout, truncation short/long).

134 tests, 1 pre-existing failure in `store_test.exs` unrelated to this ticket.
