cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
The 1 failure is the pre-existing `store_test.exs` failure, exactly as expected.

All implementation was already complete from the previous blocked attempt. Here's a summary by task:

**Task 1 — `lib/cranium/agent/tool.ex`**: `Cranium.Agent.Tool` behaviour with required `execute/2` and optional `name/0` via `@optional_callbacks`. ✓

**Task 2 — `config/config.exs`**: `config :cranium, :tools, []` added before the backends block. ✓

**Task 3 — `lib/cranium/agent/tool_router.ex`**: `register/2` backed by `Application.put_env`, `find_handler/1` private helper doing registry lookup, `route/1` dispatching to `{:execute, module, input}` or `{:unknown, name}`. ✓

**Task 4 — `lib/cranium/agent/tool_executor.ex`**: Public signature is `execute(module(), map(), keyword())`, `do_execute/3` calls `module.execute(input, opts)`, logs via `module.name()` if exported otherwise `inspect(module)`. ✓

**Task 5 — `test/cranium/agent/tool_router_test.exs`**: 3 tests (marker, unknown, registered with env restore on_exit). ✓

**Task 6 — `test/cranium/agent/tool_executor_test.exs`**: 5 tests (ok dispatch, error passthrough, timeout, truncation short/long). ✓

**Result**: 134 tests, 1 pre-existing failure in `store_test.exs`. No deviations from the plan.
