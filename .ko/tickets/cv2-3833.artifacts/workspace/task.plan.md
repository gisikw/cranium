cranium-v2 dev shell
  mix test     — run tests
  mix compile  — compile
  iex -S mix   — interactive shell
  just         — list recipes

Elixir Elixir 1.18.4 (compiled with Erlang/OTP 27)
Erlang/OTP 28
Plan written to `/home/dev/Projects/cranium-v2/.ko/tickets/cv2-3833.artifacts/plan.md`.

Here's the summary:

## Plan Summary

**Goal:** Implement real tool dispatch — `Tool` behaviour, registry lookup in `ToolRouter`, module dispatch in `ToolExecutor`.

**6 tasks:**

1. **New `lib/cranium/agent/tool.ex`** — `Cranium.Agent.Tool` behaviour with a single `execute(input, opts)` callback.

2. **`config/config.exs`** — Add `config :cranium, :tools, []` (empty now, documents the pattern).

3. **`tool_router.ex:route/1`** — Replace the `{:unknown, name}` stub with a config registry lookup returning `{:execute, module, input}` when found.

4. **`tool_executor.ex`** — Change public signature to `execute(module(), map(), keyword())` (matches ToolRouter's `{:execute, module(), map()}` return type), implement `do_execute` as `module.execute(input, opts)`.

5. **`test/.../tool_router_test.exs`** — Tests for marker routing, unknown tools, and registered tool lookup (using `Application.put_env` in setup).

6. **`test/.../tool_executor_test.exs`** — Tests for successful dispatch, error passthrough, timeout, and truncation.

**Open questions flagged:**
1. Config vs runtime registration for test isolation
2. Whether to preserve a human-readable tool name string in the executor's public API (for logging)
